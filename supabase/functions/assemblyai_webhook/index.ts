// Supabase Edge Function: assemblyai_webhook
//
// AssemblyAI POSTs here when a transcript is ready. We:
//   1. Verify the shared secret (so randos can't write fake transcripts).
//   2. Fetch the full transcript from AssemblyAI (the webhook body only has the id).
//   3. Update the corresponding recordings row with the transcript text/json.
//
// Deploy: `supabase functions deploy assemblyai_webhook --no-verify-jwt`
//         (no-verify-jwt because AssemblyAI doesn't have a Supabase JWT;
//          we authenticate via the x-webhook-secret header instead.)
//
// Secrets needed:
//   - ASSEMBLYAI_API_KEY
//   - WEBHOOK_SECRET   (same value as in submit_for_transcription)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface WebhookBody {
  transcript_id: string;
  status: "completed" | "error";
  error?: string;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const ASSEMBLYAI_API_KEY = Deno.env.get("ASSEMBLYAI_API_KEY")!;
  const WEBHOOK_SECRET = Deno.env.get("WEBHOOK_SECRET")!;
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // 1. Verify the secret.
  if (req.headers.get("x-webhook-secret") !== WEBHOOK_SECRET) {
    return new Response("Forbidden", { status: 403 });
  }

  const url = new URL(req.url);
  const recordingId = url.searchParams.get("recording_id");
  if (!recordingId) {
    return new Response("Missing recording_id", { status: 400 });
  }

  const body: WebhookBody = await req.json();
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  if (body.status === "error") {
    await supabase.from("recordings").update({
      status: "failed",
      error_message: body.error ?? "Transcription failed",
    }).eq("id", recordingId);
    return new Response("ok");
  }

  // 2. Fetch the full transcript.
  const txResp = await fetch(
    `https://api.assemblyai.com/v2/transcript/${body.transcript_id}`,
    { headers: { "Authorization": ASSEMBLYAI_API_KEY } },
  );
  if (!txResp.ok) {
    await supabase.from("recordings").update({
      status: "failed",
      error_message: `Could not fetch transcript: ${txResp.status}`,
    }).eq("id", recordingId);
    return new Response("ok");
  }
  const tx = await txResp.json();

  // 3. Write the transcript result.
  await supabase.from("recordings").update({
    status: "done",
    transcript: tx.text ?? "",
    transcript_json: tx,        // includes words[], speaker labels, timestamps
  }).eq("id", recordingId);

  // 4. Chain to extract_fields so Claude pulls structured info from the
  //    transcript. We await so failures get logged, but the webhook still
  //    returns ok regardless — extraction failure is not a transcription
  //    failure. iOS can manually re-trigger from the detail view.
  try {
    const extractResp = await fetch(`${SUPABASE_URL}/functions/v1/extract_fields`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${SERVICE_ROLE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ recording_id: recordingId }),
    });
    if (!extractResp.ok) {
      console.error(`extract_fields chain failed: ${extractResp.status} ${await extractResp.text()}`);
    }
  } catch (err) {
    console.error("extract_fields chain threw:", err);
  }

  // The iOS app's Realtime subscription will pick up both the transcript
  // and the extracted_fields update.

  return new Response("ok");
});
