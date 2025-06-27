from paddleocr import PaddleOCR
from fastapi import FastAPI, Request
import base64
from io import BytesIO
from PIL import Image

ocr = PaddleOCR(use_angle_cls=True, lang='en')  # Or 'ar' for Arabic
app = FastAPI()

@app.post("/ocr")
async def ocr_endpoint(request: Request):
    data = await request.json()
    img_data = base64.b64decode(data["image"])
    image = Image.open(BytesIO(img_data)).convert("RGB")
    result = ocr.ocr(image, cls=True)
    return {"ocr": result}
