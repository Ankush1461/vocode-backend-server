from fastapi import FastAPI, UploadFile, File
import os
import io
from tempfile import NamedTemporaryFile

app = FastAPI()

# Prefer native whisper.cpp when available to avoid installing heavy Python packages like torch.
# Set these environment variables in your Render service if you provide whisper.cpp artifacts:
# - WHISPER_CPP_LIB: path to libwhisper.so (or .dll/.dylib)
# - WHISPER_CPP_MODEL: path to the ggml model file (e.g. models/ggml-tiny.bin)

WHISPER_CPP_LIB = os.getenv("WHISPER_CPP_LIB")
WHISPER_CPP_MODEL = os.getenv("WHISPER_CPP_MODEL")

whisper_cpp = None
whisper_cpp_params = None
whisper_cpp_ctx = None

if WHISPER_CPP_LIB and WHISPER_CPP_MODEL:
    try:
        import ctypes
        from pydub import AudioSegment
        from vocode.utils.whisper_cpp.whisper_params import WhisperFullParams

        _whisper = ctypes.CDLL(WHISPER_CPP_LIB)  # type: ignore
        _whisper.whisper_init_from_file.restype = ctypes.c_void_p
        _whisper.whisper_full_default_params.restype = WhisperFullParams
        _whisper.whisper_full_get_segment_text.restype = ctypes.c_char_p

        _ctx = _whisper.whisper_init_from_file(WHISPER_CPP_MODEL.encode("utf-8"))
        _params = _whisper.whisper_full_default_params()
        _params.print_realtime = False
        _params.print_progress = False
        _params.single_segment = True

        whisper_cpp = _whisper
        whisper_cpp_params = _params
        whisper_cpp_ctx = _ctx
    except Exception:
        whisper_cpp = None
        whisper_cpp_params = None
        whisper_cpp_ctx = None


@app.post("/api/transcribe")
async def transcribe(file: UploadFile = File(...)):
    audio_bytes = await file.read()

    # 1) whisper.cpp native binary (preferred when available)
    if whisper_cpp is not None and whisper_cpp_params is not None and whisper_cpp_ctx is not None:
        from vocode.utils.whisper_cpp.helpers import transcribe as whisper_cpp_transcribe

        audio_segment = AudioSegment.from_file(io.BytesIO(audio_bytes), format="wav")
        text, confidence = whisper_cpp_transcribe(whisper_cpp, whisper_cpp_params, whisper_cpp_ctx, audio_segment)
        return {"text": text, "confidence": confidence}

    # 2) If local python `openai-whisper` is installed (development), import lazily
    try:
        import whisper

        model = whisper.load_model("base")
        with NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp.flush()
            result = model.transcribe(tmp.name)
        return {"text": result.get("text"), "language": result.get("language")}
    except Exception:
        pass

    return {
        "error": "No transcription backend available. Provide WHISPER_CPP_LIB and WHISPER_CPP_MODEL for whisper.cpp, or install openai-whisper locally for development."
    }


@app.get("/healthz")
def health_check():
    return {"status": "ok"}
