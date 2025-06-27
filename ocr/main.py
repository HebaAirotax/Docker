import base64
import io
import time
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from PIL import Image
from pdf2image import convert_from_bytes
from rapidocr_onnxruntime import RapidOCR

app = FastAPI()

ocr = RapidOCR(
    det_model_path="models/en_PP-OCRv3_det_infer.onnx",
    rec_model_path="models/en_PP-OCRv4_rec_server_infer.onnx",
    cls_model_path="models/ch_ppocr_mobile_v2.0_cls_train.onnx"
)

class OCRRequest(BaseModel):
    image_base64: str | None = None
    pdf_base64: str | None = None

def midpoint(box):
    x = [pt[0] for pt in box]
    y = [pt[1] for pt in box]
    return sum(x) / len(x), sum(y) / len(y)

def clean_text_lines(text_lines, row_threshold=20):
    # Step 1: Normalize into midpoints
    normalized = []
    for line in text_lines:
        box, text = line[:2]
        mid_x, mid_y = midpoint(box)
        normalized.append({'text': text, 'x': mid_x, 'y': mid_y})

    # Step 2: Group by Y (rows)
    normalized.sort(key=lambda i: i['y'])
    rows = []
    for item in normalized:
        placed = False
        for row in rows:
            if abs(row[0]['y'] - item['y']) < row_threshold:
                row.append(item)
                placed = True
                break
        if not placed:
            rows.append([item])

    # Step 3: Sort each row left-to-right
    for row in rows:
        row.sort(key=lambda i: i['x'])

    # Step 4: Rebuild into lines
    final_lines = []
    for row in rows:
        line = "\t".join([item['text'] for item in row])
        final_lines.append(line)

    return "\n".join(final_lines)

@app.post("/ocr")
def run_ocr(data: OCRRequest):
    pages = []

    if data.image_base64:
        try:
            img_data = base64.b64decode(data.image_base64)
            image = Image.open(io.BytesIO(img_data)).convert("RGB")
            pages = [image]
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid base64 image")

    elif data.pdf_base64:
        try:
            pdf_data = base64.b64decode(data.pdf_base64)
            pages = convert_from_bytes(pdf_data, dpi=500)  # high quality
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid base64 PDF")

    else:
        raise HTTPException(status_code=400, detail="No valid input provided")

    results = []
    for idx, page in enumerate(pages):
        start = time.time()
        text_lines, _ = ocr(page)
        duration = round(time.time() - start, 2)

        cleaned_text = clean_text_lines(text_lines)

        results.append({
            "page": idx + 1,
            "text": cleaned_text,
            "lines": [
                {"text": line[1], "box": line[0]} for line in text_lines
            ],
            "time": duration
        })

    return {"pages": results}
