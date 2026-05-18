#!/usr/bin/env python3
"""
Generate sample fillable PDF templates into ../templates/.

Both PDFs are real AcroForm PDFs — the iOS app reads the field names via
PDFKit at upload time, then Claude maps a recording's extracted fields
onto them.

Usage:
    pip3 install --user reportlab
    python3 scripts/generate-sample-templates.py
"""

from pathlib import Path
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.colors import black, gray, white
from reportlab.lib.units import inch
from reportlab.pdfgen import canvas


REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "templates"
OUT_DIR.mkdir(exist_ok=True)


def draw_header(c: canvas.Canvas, title: str, subtitle: str) -> None:
    c.setFillColor(black)
    c.setFont("Helvetica-Bold", 20)
    c.drawString(0.75 * inch, 10.2 * inch, title)
    c.setFillColor(gray)
    c.setFont("Helvetica", 10)
    c.drawString(0.75 * inch, 9.92 * inch, subtitle)
    c.setStrokeColor(gray)
    c.setLineWidth(0.5)
    c.line(0.75 * inch, 9.78 * inch, 7.75 * inch, 9.78 * inch)


def label(c: canvas.Canvas, x: float, y: float, text: str) -> None:
    c.setFillColor(gray)
    c.setFont("Helvetica", 8)
    c.drawString(x, y, text.upper())


def text_field(
    c: canvas.Canvas,
    name: str,
    label_text: str,
    x: float,
    y: float,
    width: float,
    height: float = 0.32 * inch,
    multiline: bool = False,
) -> None:
    """Draw a label + a fillable text field underneath."""
    label(c, x, y + height + 0.06 * inch, label_text)
    c.acroForm.textfield(
        name=name,
        tooltip=label_text,
        x=x,
        y=y,
        width=width,
        height=height,
        borderColor=gray,
        fillColor=white,
        textColor=black,
        borderStyle="underlined",
        borderWidth=0.5,
        forceBorder=True,
        fieldFlags="multiline" if multiline else "",
    )


def make_personal_intake() -> None:
    """A generic personal-info form. Field names are tuned for the kind of
    short self-introduction recording you'd typically do for a demo."""
    out = OUT_DIR / "personal-intake-form.pdf"
    c = canvas.Canvas(str(out), pagesize=LETTER)
    draw_header(
        c,
        "Personal Intake Form",
        "Auto-fillable from a recorded self-introduction.",
    )

    x = 0.75 * inch
    width = 6.6 * inch
    half = (width - 0.2 * inch) / 2
    y = 9.0 * inch
    gap = 0.72 * inch

    text_field(c, "full_name", "Full name", x, y, width)
    y -= gap

    text_field(c, "date_of_birth", "Date of birth", x, y, half)
    text_field(c, "age", "Age", x + half + 0.2 * inch, y, half)
    y -= gap

    text_field(c, "email", "Email", x, y, half)
    text_field(c, "phone_number", "Phone number", x + half + 0.2 * inch, y, half)
    y -= gap

    text_field(c, "address", "Address (street)", x, y, width)
    y -= gap

    third = (width - 0.4 * inch) / 3
    text_field(c, "city", "City", x, y, third)
    text_field(c, "state", "State", x + third + 0.2 * inch, y, third)
    text_field(c, "zip_code", "ZIP code", x + 2 * (third + 0.2 * inch), y, third)
    y -= gap

    text_field(c, "occupation", "Occupation", x, y, half)
    text_field(c, "employer", "Employer", x + half + 0.2 * inch, y, half)
    y -= gap

    text_field(c, "summary", "Summary / about me", x, y - 1.0 * inch, width, height=1.4 * inch, multiline=True)

    c.setFillColor(gray)
    c.setFont("Helvetica-Oblique", 8)
    c.drawString(x, 0.5 * inch, "TranscriptionAPPMVP — sample fillable template. All fields are AcroForm text fields with named keys.")

    c.save()
    print(f"wrote {out.relative_to(REPO_ROOT)}")


def make_meeting_summary() -> None:
    """A meeting-recap template. Designed for the demo meeting paragraph."""
    out = OUT_DIR / "meeting-summary-form.pdf"
    c = canvas.Canvas(str(out), pagesize=LETTER)
    draw_header(
        c,
        "Meeting Summary",
        "Auto-fillable from a recorded planning conversation.",
    )

    x = 0.75 * inch
    width = 6.6 * inch
    half = (width - 0.2 * inch) / 2
    y = 9.0 * inch
    gap = 0.72 * inch

    text_field(c, "meeting_title", "Meeting title", x, y, width)
    y -= gap

    text_field(c, "meeting_date", "Date", x, y, half)
    text_field(c, "next_meeting", "Next meeting", x + half + 0.2 * inch, y, half)
    y -= gap

    text_field(c, "attendees", "Attendees", x, y, width)
    y -= gap

    text_field(c, "summary", "Summary", x, y - 1.0 * inch, width, height=1.4 * inch, multiline=True)
    y -= gap + 1.0 * inch

    text_field(c, "action_items", "Action items", x, y - 1.0 * inch, width, height=1.4 * inch, multiline=True)
    y -= gap + 1.0 * inch

    text_field(c, "decisions", "Decisions", x, y - 0.7 * inch, width, height=1.0 * inch, multiline=True)

    c.setFillColor(gray)
    c.setFont("Helvetica-Oblique", 8)
    c.drawString(x, 0.5 * inch, "TranscriptionAPPMVP — sample fillable template. All fields are AcroForm text fields with named keys.")

    c.save()
    print(f"wrote {out.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    make_personal_intake()
    make_meeting_summary()
    print("\nDone. Two sample fillable PDFs are in templates/.")
    print("Upload them through the iOS app's 'Fill a PDF template' button.")
