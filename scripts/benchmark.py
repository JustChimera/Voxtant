"""Bounded OpenRouter comparison on saved audio; the API key never leaves process memory."""
import argparse
import base64
import json
import pathlib
import subprocess
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("docs/benchmark-raw.json"))
    parser.add_argument("--models", nargs="+", default=["google/gemini-2.5-flash-lite", "google/gemini-2.5-flash"])
    parser.add_argument("--ids", nargs="+", type=int, default=[6, 10, 11])
    args = parser.parse_args()
    root = pathlib.Path.home() / "Library/Application Support/LectureTranslateDemo/Sessions"
    folder = args.session or max(root.glob("*/session.json"), key=lambda p: p.stat().st_mtime).parent
    report = json.loads((folder / "session.json").read_text())
    credential = subprocess.run(
        ["security", "find-generic-password", "-s", "local.lecturetranslate.demo.openrouter", "-a", "api-key", "-w"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if credential.returncode:
        raise SystemExit("Keychain access unavailable; no API requests were sent.")
    key = credential.stdout.decode().strip()
    if not key:
        raise SystemExit("Keychain entry is empty.")
    results = []
    for segment in report["segments"]:
        if segment["id"] not in args.ids:
            continue
        audio = base64.b64encode((folder / segment["file"]).read_bytes()).decode()
        for model in args.models:
            prompt = (
                "Transcribe ONLY the audible speech in this recording. This is a Mandarin Chinese lesson "
                "explained in English, with frequent code-switching to Mandarin. Write English as English; "
                "write spoken Mandarin as simplified Chinese Han characters, NEVER English phonetic spellings "
                "or pinyin. Do not translate or explain. Do not invent unclear words. "
                "Return only the verbatim transcript."
            )
            body = {
                "model": model, "temperature": 0, "max_tokens": 256,
                "messages": [{"role": "user", "content": [
                    {"type": "text", "text": prompt},
                    {"type": "input_audio", "input_audio": {"data": audio, "format": "wav"}},
                ]}],
            }
            request = urllib.request.Request(
                "https://openrouter.ai/api/v1/chat/completions",
                data=json.dumps(body).encode(),
                headers={"Authorization": "Bearer " + key, "Content-Type": "application/json", "X-Title": "Voxtant Benchmark"},
            )
            started = time.monotonic()
            row = {"segment": segment["id"], "model": model, "baseline": segment["transcript"]}
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    data = json.load(response)
                row.update(text=data["choices"][0]["message"]["content"], cost=data.get("usage", {}).get("cost"))
            except urllib.error.HTTPError as error:
                detail = error.read().decode(errors="replace").replace(key, "[redacted]")
                row.update(error=detail[:1500], status=error.code)
            except Exception as error:
                row["error"] = str(error).replace(key, "[redacted]")[:500]
            row["seconds"] = round(time.monotonic() - started, 3)
            results.append(row)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps({"session": folder.name, "results": results}, ensure_ascii=False, indent=2) + "\n")
            print(json.dumps(row, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
