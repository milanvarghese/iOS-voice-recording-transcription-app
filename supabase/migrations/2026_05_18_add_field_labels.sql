-- Adds the field_labels column to pdf_templates so we can persist the
-- human-readable PDF widget label alongside the internal field name.
-- The label is what the LLM uses to semantically map transcript content
-- onto each field (the internal name is often opaque, e.g. "Text1").
--
-- Safe to run multiple times on existing databases.

alter table public.pdf_templates
  add column if not exists field_labels jsonb;
