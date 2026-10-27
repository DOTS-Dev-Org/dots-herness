#!/usr/bin/env python3
"""Local music server for the Media music studio.

Serves MusicGen behind the request the app sends for one track:

    GET  /v1/models
    POST /v1/audio/generations  {"model", "prompt", "duration", "instrument"?, "bpm"?, "key"?, "lyrics"?}

The reply is a WAV file. Errors are {"error": {"message": ...}}.

    pip install torch transformers fastapi uvicorn
    python tools/music_server.py            # http://127.0.0.1:8090/v1

In the app: Media models > Music > Connect API, type Standard, this address.
The first request for a model downloads it from Hugging Face.
"""

import argparse
import io
import math
import os
import threading
import wave

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import numpy as np
import torch
import uvicorn
from fastapi import FastAPI
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel
from transformers import AutoProcessor, MusicgenForConditionalGeneration

# ponytail: mono checkpoints only; the stereo ones need a two-channel audio prompt in `render`.
MODELS = {name: f"facebook/{name}" for name in ("musicgen-small", "musicgen-medium", "musicgen-large")}
FRAMES_PER_SECOND = 50  # MusicGen audio tokens per second
DELAY = 3  # frames each pass loses to the codebook delay pattern, asked for on top
WINDOW = 29  # seconds per pass; with DELAY it stays inside the model's 30-second limit
CONTEXT = 10  # seconds of the previous window a longer track continues from
MAX_SECONDS = 600

DEVICE = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"

app = FastAPI()
lock = threading.Lock()  # one render at a time: they share the model and the GPU
loaded = {}  # at most one model, so switching does not keep two in memory


class Generation(BaseModel):
    model: str
    prompt: str
    duration: int = 15
    instrument: str | None = None
    bpm: int | None = None
    key: str | None = None
    lyrics: str | None = None


def error(status, message):
    return JSONResponse({"error": {"message": message}}, status_code=status)


def load(name):
    if name not in loaded:
        loaded.clear()
        processor = AutoProcessor.from_pretrained(MODELS[name])
        model = MusicgenForConditionalGeneration.from_pretrained(MODELS[name]).to(DEVICE)
        loaded[name] = (processor, model)
    return loaded[name]


def render(name, prompt, seconds):
    """Mono float samples and their rate. Past one window, each pass continues from the tail of the last."""
    processor, model = load(name)
    rate = model.config.audio_encoder.sampling_rate
    total = seconds * rate
    audio = np.zeros(0, dtype=np.float32)
    while len(audio) < total:
        missing = (total - len(audio)) / rate
        if len(audio) == 0:
            inputs = processor(text=[prompt], padding=True, return_tensors="pt")
            kept, new = 0, min(missing, WINDOW)
        else:
            kept = min(CONTEXT * rate, len(audio))
            inputs = processor(
                audio=audio[-kept:], sampling_rate=rate, text=[prompt], padding=True, return_tensors="pt"
            )
            new = min(missing, WINDOW - CONTEXT)
        with torch.no_grad():
            out = model.generate(
                **inputs.to(DEVICE), do_sample=True, guidance_scale=3.0,
                max_new_tokens=math.ceil(new * FRAMES_PER_SECOND) + DELAY,
            )
        # The output starts with the audio it was prompted with; only what follows is new.
        fresh = out[0, 0].float().cpu().numpy()[kept:]
        if len(fresh) == 0:  # a pass that adds nothing would repeat forever
            break
        audio = np.concatenate([audio, fresh])
    audio = np.pad(audio[:total], (0, max(total - len(audio), 0)))
    fade = min(rate // 20, len(audio))
    audio[len(audio) - fade:] *= np.linspace(1, 0, fade, dtype=np.float32)
    return audio, rate


def wav(audio, rate):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
    return buffer.getvalue()


@app.get("/v1/models")
def models():
    return {"object": "list", "data": [{"id": name, "object": "model"} for name in MODELS]}


@app.post("/v1/audio/generations")
def generations(request: Generation):
    if request.model not in MODELS:
        return error(404, f"Unknown model '{request.model}'. Available: {', '.join(MODELS)}.")
    if not request.prompt.strip():
        return error(422, "The prompt is empty.")
    if request.lyrics:
        return error(422, "MusicGen plays instruments only and cannot sing. Generate vocal tracks on an API that sings.")
    if not 1 <= request.duration <= MAX_SECONDS:
        return error(422, f"Duration must be between 1 and {MAX_SECONDS} seconds.")
    with lock:
        audio, rate = render(request.model, request.prompt, request.duration)
    return Response(wav(audio, rate), media_type="audio/wav")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1", help="address to listen on; the default accepts this machine only")
    parser.add_argument("--port", type=int, default=8090)
    args = parser.parse_args()
    uvicorn.run(app, host=args.host, port=args.port)
