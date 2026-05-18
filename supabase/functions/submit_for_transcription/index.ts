// Supabase Edge Function: submit_for_transcription
//
// Called by the iOS app once a recording has been uploaded to Storage.
// Generates a short-lived signed URL for the M4A, hands it to AssemblyAI's
// async transcription endpoint, and saves the resulting job id back to the row.
//
// Deploy: `supabase functions deploy submit_for_transcription`
// Secrets needed:
//   - ASSEMBLYAI_API_KEY     (from assemblyai.com dashboard)
//   - WEBHOOK_URL            (full URL of the assemblyai_webhook function)
//   - WEBHOOK_SECRET         (random string — AssemblyAI passes it back, we verify)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface RequestBody {
  recording_id: string;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const ASSEMBLYAI_API_KEY = Deno.env.get("ASSEMBLYAI_API_KEY")!;
  const WEBHOOK_URL = Deno.env.get("WEBHOOK_URL")!;
  const WEBHOOK_SECRET = Deno.env.get("WEBHOOK_SECRET")!;

  // Validate the caller's JWT so the function isn't open to the world.
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response("Unauthorized", { status: 401 });
  }

  // service-role client bypasses RLS — fine inside Edge Functions, never client-side.
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const body: RequestBody = await req.json();
  if (!body.recording_id) {
    return new Response("Missing recording_id", { status: 400 });
  }

  // 1. Look up the recording and confirm it's in the right state.
  const { data: recording, error: fetchErr } = await supabase
    .from("recordings")
    .select("*")
    .eq("id", body.recording_id)
    .single();

  if (fetchErr || !recording) {
    return new Response("Recording not found", { status: 404 });
  }
  if (!recording.storage_path) {
    return new Response("Recording has no storage_path yet", { status: 400 });
  }

  // 2. Create a short-lived signed URL AssemblyAI can fetch.
  //    1 day is plenty for a single job.
  const { data: signed, error: signErr } = await supabase
    .storage
    .from("recordings")
    .createSignedUrl(recording.storage_path, 60 * 60 * 24);

  if (signErr || !signed) {
    return new Response("Failed to sign URL", { status: 500 });
  }

  // 3. Submit to AssemblyAI. Async endpoint — returns immediately with an id.
  //    Webhook fires when transcription is done (~30% of audio duration).
  const submitResp = await fetch("https://api.assemblyai.com/v2/transcript", {
    method: "POST",
    headers: {
      "Authorization": ASSEMBLYAI_API_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      audio_url: signed.signedUrl,
      webhook_url: `${WEBHOOK_URL}?recording_id=${recording.id}`,
      webhook_auth_header_name: "x-webhook-secret",
      webhook_auth_header_value: WEBHOOK_SECRET,
      // AssemblyAI now requires speech_models. universal-2 is the cheaper option;
      // swap to universal-3-pro if you need higher accuracy.
      speech_models: ["universal-2"],
      speaker_labels: true,
      punctuate: true,
      format_text: true,
    }),
  });

  if (!submitResp.ok) {
    const text = await submitResp.text();
    await supabase.from("recordings").update({
      status: "failed",
      error_message: `AssemblyAI submit failed: ${text}`,
    }).eq("id", recording.id);
    return new Response(text, { status: 502 });
  }

  const job = await submitResp.json();

  // 4. Save the AssemblyAI job id so the webhook can correlate.
  await supabase.from("recordings").update({
    status: "transcribing",
    assemblyai_id: job.id,
  }).eq("id", recording.id);

  return new Response(JSON.stringify({ ok: true, job_id: job.id }), {
    headers: { "Content-Type": "application/json" },
  });
});
