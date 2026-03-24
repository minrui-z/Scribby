import argparse
import json
import warnings
from pathlib import Path

import engine


EVENT_PREFIX = "__EVENT__:"
warnings.filterwarnings(
    "ignore",
    message=r"resource_tracker: There appear to be .* leaked semaphore objects",
    category=UserWarning,
)


def emit(event, data):
    payload = {"event": event, "data": data}
    print(f"{EVENT_PREFIX}{json.dumps(payload, ensure_ascii=False)}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-path", required=True)
    parser.add_argument("--language", default="zh")
    parser.add_argument("--diarize", action="store_true")
    parser.add_argument("--speakers", type=int, default=0)
    parser.add_argument("--token", default="")
    parser.add_argument("--output-path", required=True)
    parser.add_argument("--download-url", required=True)
    args = parser.parse_args()

    def on_progress(event_type, message):
        emit(event_type, {"type": event_type, "message": message})

    try:
        result = engine.transcribe(
            args.audio_path,
            language=args.language,
            on_progress=on_progress,
        )

        segments = result.get("segments", [])
        detected_language = result.get("language", args.language)

        lines = [engine.format_segment(seg, False) for seg in segments]
        transcript = "\n".join(lines)
        emit(
            "transcript",
            {
                "text": transcript,
                "language": detected_language,
                "count": len(segments),
            },
        )

        has_speakers = False
        if args.diarize and args.token:
            emit(
                "status",
                {"type": "status", "message": "正在進行語者分離..."},
            )
            num_speakers = args.speakers if args.speakers > 0 else None
            segments = engine.diarize(
                args.audio_path,
                segments,
                args.token,
                num_speakers,
            )
            has_speakers = True

        lines = [engine.format_segment(seg, has_speakers) for seg in segments]
        final_transcript = "\n".join(lines)

        output_path = Path(args.output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(final_transcript, encoding="utf-8")

        emit(
            "done",
            {
                "text": final_transcript,
                "language": detected_language,
                "count": len(segments),
                "has_speakers": has_speakers,
                "download": args.download_url,
            },
        )
    except Exception as exc:
        emit("error", {"message": str(exc)})
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()
