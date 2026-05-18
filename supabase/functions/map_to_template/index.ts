// Supabase Edge Function: map_to_template
//
// Given a recording (transcript + extracted_fields) and a PDF template
// (its list of named form fields), asks Claude Sonnet 4.6 to produce a
// flat {field_name: string} mapping. iOS uses that mapping to fill in
// the PDF locally with PDFKit.
//
// We do mapping here (server-side) so the Anthropic key stays out of the
// app, and PDF filling on iOS (client-side) so we don't need a PDF
// library in Deno and the user gets the filled PDF without an extra
// Storage round-trip.
//
// Deploy: `supabase functions deploy map_to_template`

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface RequestBody {
  recording_id: string;
  template_id: string;
}

const SYSTEM_PROMPT = `You map information from a transcribed audio recording onto the named form fields of a fillable PDF.

Inputs you'll be given:
1. An array of PDF form field names (e.g., ["full_name", "date_of_birth", "city", "phone_number"]).
2. A JSON object of structured fields already extracted from the transcript.
3. The full transcript text, in case the JSON object is missing something the form needs.

Return a single JSON object whose keys EXACTLY match the field names supplied to you, and whose values are strings appropriate to fill those fields. Rules:

- Match field names by semantic meaning, not exact name. PDF "patient_name" matches JSON "name" or transcript mentions of a person. PDF "dob" matches "date_of_birth".
- Coerce values to strings:
  - Dates → natural readable format, e.g., "January 15, 1995" or "1995-01-15" if the form looks numeric.
  - Numbers → numerals as strings, e.g., "26".
  - Lists → join with ", " or "; " as appropriate for a single form field.
  - Booleans → "Yes" / "No".
- If a field has no clear value in the source data, return an empty string. NEVER invent.
- Keys in the output JSON must EXACTLY match the field names provided. Don't add, rename, or drop keys.
- Return ONLY the JSON object — no markdown fences, no commentary, no preamble.`;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

  if (!ANTHROPIC_API_KEY) {
    return new Response("ANTHROPIC_API_KEY not configured", { status: 500 });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response("Invalid JSON body", { status: 400 });
  }
  if (!body.recording_id || !body.template_id) {
    return new Response("Missing recording_id or template_id", { status: 400 });
  }

  // Load template field names
  const { data: template, error: tErr } = await supabase
    .from("pdf_templates")
    .select("name, field_names")
    .eq("id", body.template_id)
    .single();
  if (tErr || !template) {
    return new Response("Template not found", { status: 404 });
  }
  const fieldNames: string[] = Array.isArray(template.field_names) ? template.field_names : [];
  if (fieldNames.length === 0) {
    return new Response("Template has no detected form fields", { status: 400 });
  }

  // Load recording
  const { data: recording, error: rErr } = await supabase
    .from("recordings")
    .select("transcript, extracted_fields")
    .eq("id", body.recording_id)
    .single();
  if (rErr || !recording) {
    return new Response("Recording not found", { status: 404 });
  }
  const transcript = (recording.transcript ?? "").trim();
  if (!transcript) {
    return new Response("Recording has no transcript yet", { status: 400 });
  }
  const extracted = recording.extracted_fields ?? {};

  // Call Claude
  const userPrompt = `Template: ${template.name}

PDF form fields to fill:
${JSON.stringify(fieldNames, null, 2)}

Structured fields extracted from the transcript:
${JSON.stringify(extracted, null, 2)}

Full transcript (for anything not in the structured fields):
---
${transcript}
---

Return the flat JSON mapping now.`;

  const claudeResp = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-sonnet-4-6",
      max_tokens: 2048,
      system: [
        {
          type: "text",
          text: SYSTEM_PROMPT,
          cache_control: { type: "ephemeral" },
        },
      ],
      messages: [
        { role: "user", content: userPrompt },
      ],
    }),
  });

  if (!claudeResp.ok) {
    const text = await claudeResp.text();
    return new Response(JSON.stringify({ error: `Claude ${claudeResp.status}: ${text}` }), {
      status: 502,
      headers: { "Content-Type": "application/json" },
    });
  }

  const claudeData = await claudeResp.json();
  let raw: string = claudeData.content?.[0]?.text ?? "";
  raw = raw.trim();
  if (raw.startsWith("```json")) raw = raw.slice(7).trim();
  if (raw.startsWith("```")) raw = raw.slice(3).trim();
  if (raw.endsWith("```")) raw = raw.slice(0, -3).trim();

  let mapping: Record<string, string>;
  try {
    mapping = JSON.parse(raw);
  } catch (_e) {
    return new Response(JSON.stringify({ error: "Invalid JSON from model", raw }), {
      status: 502,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Enforce schema: keys must be in fieldNames, values must be strings.
  const cleaned: Record<string, string> = {};
  for (const name of fieldNames) {
    const v = mapping[name];
    cleaned[name] = typeof v === "string" ? v : (v == null ? "" : String(v));
  }

  return new Response(JSON.stringify({ ok: true, mapping: cleaned }), {
    headers: { "Content-Type": "application/json" },
  });
});
