// Supabase Edge Function: extract_fields
//
// Reads a recording's transcript, asks Claude Sonnet 4.6 to extract a flexible
// JSON object of relevant fields (the schema adapts to the content: a meeting
// gets meeting fields, a shopping list gets items, etc.), and saves it back
// to recordings.extracted_fields.
//
// Called automatically by assemblyai_webhook once the transcript lands. iOS
// can also call it directly for manual re-extraction from the detail view.
//
// Deploy: `supabase functions deploy extract_fields`
// Secrets needed:
//   - ANTHROPIC_API_KEY       (from console.anthropic.com)
//   - SUPABASE_URL            (auto-injected)
//   - SUPABASE_SERVICE_ROLE_KEY (auto-injected)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface RequestBody {
  recording_id: string;
}

// Cached on Anthropic's side via cache_control: ephemeral. Saves cost when
// AssemblyAI fires several webhooks in quick succession.
const SYSTEM_PROMPT = `You are an information extraction system for transcribed audio recordings.

Given a transcript, produce a JSON object with the most relevant fields for the content. Adapt the schema to what's actually being said:
- Business meeting → attendees, decisions, action_items, deadlines, next_meeting
- Shopping list → items (with quantity), store, budget
- Medical complaint → symptoms, duration, severity, medications_mentioned, family_history
- Sales call → customer_name, pain_points, current_solution, next_steps, budget_signals
- Personal voice memo → main_idea, todos, ideas, mood, references_to_remember
- Interview → interviewee, topics, key_quotes, follow_ups
- Lecture or class notes → subject, key_concepts, examples, questions_to_ask

Rules:
1. Always include a "summary" field with a 1–2 sentence overview.
2. Use snake_case lowercase keys.
3. Only include fields with content actually present in the transcript. Skip empty arrays and null fields entirely.
4. Don't invent information. If the transcript doesn't mention something, leave that field out.
5. For multi-value content use arrays; for single values use strings.
6. Return ONLY a single valid JSON object. No markdown fences, no preamble, no commentary.`;

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

  // The gateway validates the JWT (verify_jwt=true) so any reachable caller
  // is already authorized at the Supabase level. The webhook calls us with
  // the service-role key, which is a valid JWT.
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
  if (!body.recording_id) {
    return new Response("Missing recording_id", { status: 400 });
  }

  // 1. Load the transcript.
  const { data: recording, error: fetchErr } = await supabase
    .from("recordings")
    .select("id, transcript")
    .eq("id", body.recording_id)
    .single();

  if (fetchErr || !recording) {
    return new Response("Recording not found", { status: 404 });
  }
  const transcript = (recording.transcript ?? "").trim();
  if (!transcript) {
    return new Response("Recording has no transcript yet", { status: 400 });
  }

  // 2. Ask Claude. Sonnet 4.6 is current best for structured extraction.
  //    Tool use would lock us into a fixed schema; we want flexibility, so
  //    we instruct strongly via system prompt and parse the response.
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
        {
          role: "user",
          content: `Extract structured fields from this transcript:\n\n---\n${transcript}\n---`,
        },
      ],
    }),
  });

  if (!claudeResp.ok) {
    const text = await claudeResp.text();
    console.error(`Claude API error ${claudeResp.status}: ${text}`);
    return new Response(JSON.stringify({ error: `Claude ${claudeResp.status}: ${text}` }), {
      status: 502,
      headers: { "Content-Type": "application/json" },
    });
  }

  const claudeData = await claudeResp.json();
  let raw: string = claudeData.content?.[0]?.text ?? "";

  // Strip markdown fences if Claude included them despite instructions.
  raw = raw.trim();
  if (raw.startsWith("```json")) raw = raw.slice(7).trim();
  if (raw.startsWith("```")) raw = raw.slice(3).trim();
  if (raw.endsWith("```")) raw = raw.slice(0, -3).trim();

  let extracted: unknown;
  try {
    extracted = JSON.parse(raw);
  } catch (_e) {
    console.error("Claude returned non-JSON:", raw);
    return new Response(JSON.stringify({ error: "Invalid JSON from model", raw }), {
      status: 502,
      headers: { "Content-Type": "application/json" },
    });
  }

  // 3. Save to the row. Realtime fans this out to the iOS app.
  const { error: updateErr } = await supabase
    .from("recordings")
    .update({ extracted_fields: extracted })
    .eq("id", recording.id);

  if (updateErr) {
    return new Response(JSON.stringify({ error: updateErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ ok: true, extracted }), {
    headers: { "Content-Type": "application/json" },
  });
});
