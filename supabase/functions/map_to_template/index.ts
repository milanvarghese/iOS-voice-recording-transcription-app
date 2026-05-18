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

You will receive each form field as an object: { "name": "<internal id>", "label": "<human title or null>" }.
The "name" is the opaque internal id that the keys in your output MUST match exactly.
The "label" is the visible title of the field shown to a person filling the form (e.g. "Patient's full name", "Date of birth"). Use the label as the PRIMARY signal for what the field is asking for. Only fall back to parsing the internal name when label is null.

You will also receive:
- A JSON object of structured fields already extracted from the transcript.
- The full transcript text, in case the structured fields are missing something the form needs.

Return a single JSON object whose keys EXACTLY match each field's "name", and whose values are strings appropriate to fill those fields. Rules:

- Match the label/name to source data by semantic meaning, not exact match. A field labelled "Patient's full name" matches JSON "name" or a person mentioned in the transcript. "DOB" matches "date_of_birth".
- If the label clearly asks for information that is present in the transcript or extracted fields, you MUST fill it — do not leave it blank just because the wording isn't identical.
- Coerce values to strings:
  - Dates → natural readable format, e.g., "January 15, 1995" or "1995-01-15" if the form looks numeric.
  - Numbers → numerals as strings, e.g., "26".
  - Lists → join with ", " or "; " as appropriate for a single form field.
  - Booleans → "Yes" / "No".
- If, after considering the label/name and all source data, a field truly has no value, return an empty string. NEVER invent.
- Keys in the output JSON must EXACTLY match the "name" values provided. Don't add, rename, or drop keys.
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

  // Load template field names + labels
  const { data: template, error: tErr } = await supabase
    .from("pdf_templates")
    .select("name, field_names, field_labels")
    .eq("id", body.template_id)
    .single();
  if (tErr || !template) {
    return new Response("Template not found", { status: 404 });
  }
  const fieldNames: string[] = Array.isArray(template.field_names) ? template.field_names : [];
  if (fieldNames.length === 0) {
    return new Response("Template has no detected form fields", { status: 400 });
  }
  const fieldLabels: Record<string, string> =
    template.field_labels && typeof template.field_labels === "object"
      ? template.field_labels as Record<string, string>
      : {};
  // What Claude actually sees: each field as { name, label }. Label is the
  // visible title of the form widget; falls back to null when the PDF
  // creator didn't set one, in which case Claude is told to parse the name.
  const fields = fieldNames.map((name) => ({
    name,
    label: fieldLabels[name] ?? null,
  }));

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

PDF form fields to fill (each is {name, label} — match values by label first):
${JSON.stringify(fields, null, 2)}

Structured fields extracted from the transcript:
${JSON.stringify(extracted, null, 2)}

Full transcript (for anything not in the structured fields):
---
${transcript}
---

Return the flat JSON mapping now. Keys must be the "name" values above.`;

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
