# templates/

Folder for **fillable PDF templates** you upload to the app. Tracked in git so collaborators and CI see the same sample data.

Drop any fillable PDFs you want to keep in version control here. Note: PDFs are binary and don't diff cleanly, so don't go wild — only commit the ones you actually need as canonical samples.

## What is a "fillable" PDF?

A PDF with **annotation-level form fields** — the kind you can click into and type into in Preview / Acrobat / browser. The fields have internal names like `full_name`, `date_of_birth`, `city`. The app reads those names via PDFKit at upload time and stores them so Claude can later map your recording's data into them.

**Not fillable:** a regular scanned/static PDF where you can't click to type. The app will refuse to upload these with the message "That PDF has no fillable form fields."

## How to make a fillable PDF

The fastest path on macOS:

1. Open any PDF in **Preview**.
2. **Tools → Annotate → Add Form Field** (or use Preview's annotation toolbar).
3. Drop a text field over each blank line you want fillable.
4. **For each field, set a name** in the inspector (right sidebar). Use snake_case names like `full_name`, `date_of_birth`, `phone_number`, `city`. The model uses these names to figure out what to put there.
5. Save.

Or use **Adobe Acrobat** if you have it — its form-field tool is more polished.

## Suggested field names (so Claude maps them reliably)

| Use case | Good field names |
|---|---|
| Personal / intake | `full_name`, `first_name`, `last_name`, `date_of_birth`, `age`, `email`, `phone_number`, `address`, `city`, `state`, `zip_code`, `country` |
| Meeting recap | `meeting_date`, `meeting_title`, `attendees`, `action_items`, `decisions`, `next_meeting` |
| Medical intake | `patient_name`, `dob`, `symptoms`, `duration`, `medications`, `allergies`, `notes` |
| Sales call | `customer_name`, `company`, `pain_points`, `next_steps`, `budget`, `decision_maker` |
| Inspection / contractor | `property_address`, `inspector`, `inspection_date`, `findings`, `recommendations` |

Claude maps semantically (`patient_name` ↔ "Milan Varghese" mentioned in transcript), so you don't have to match field names exactly — but using clear names helps.

## Where templates actually live once uploaded

Uploaded templates go to **Supabase Storage** in the `pdf-templates` bucket, scoped per-user under `<user_id>/<template_id>.pdf` with RLS so users can only access their own. A matching row in `public.pdf_templates` carries the name + detected field names.

To list what's currently uploaded:

```bash
SUPABASE_PAT=sbp_your_personal_access_token ./scripts/list-templates.sh
```

See `scripts/list-templates.sh` for that.
