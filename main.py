from fastapi import FastAPI, UploadFile, File
import whisper

app = FastAPI()

# Loads model ONCE at startup!
model = whisper.load_model("base")

@app.post("/api/transcribe")
async def transcribe(file: UploadFile = File(...)):
    audio_bytes = await file.read()
    with open("temp.wav", "wb") as f:
        f.write(audio_bytes)
    result = model.transcribe("temp.wav")
    return {"text": result["text"], "language": result["language"]}

@app.get("/healthz")
def health_check():
    return {"status": "ok"}
