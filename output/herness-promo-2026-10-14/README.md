# DOTS HerNess social promo set

Three Turkish, vertical 9:16 promotional-video variations for HerNess.

## Deliverables

- `renders/01-workspace.mp4` — one workspace for projects, bots, and scheduled tasks
- `renders/02-build.mp4` — coding and project-development flow
- `renders/03-tasks.mp4` — recurring task planning
- `01-workspace.srt`, `02-build.srt`, `03-tasks.srt` — editable Turkish captions
- `posters/` — portrait preview frames
- `assets/` — generated backgrounds and the existing HerNess mascot asset
- `render_promo.py` — reproducible local render script
- `PROMPTS.md` and `copy.md` — image prompts and narration/copy

Each MP4 is 1080 × 1920, 30 fps, approximately 15 seconds, H.264/AAC. Turkish narration uses the on-device macOS Yelda voice. The background score is synthesized locally for these edits.

The interface cards are clean promotional redraws based on the visible Home and Tasks screens and their actual Turkish labels. They are not raw application screenshots. No conversation content is shown.

## Render again

On macOS, with FFmpeg and the Turkish `Yelda` system voice installed:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python render_promo.py
```

The renderer uses Pillow 12.3.0 and FFmpeg 8.1.2. It writes only to this folder.

## Production approach

OpenMontage is an agent-led production workflow with multiple pipelines and a Remotion/FFmpeg composition path. I used its production-planning approach, then kept rendering local with FFmpeg and Pillow. Remotion was evaluated but not added to the project: its current license separates free use for individuals and teams up to three from company use, and the team's eligibility was not established. This also avoids adding video-rendering dependencies to the HerNess app.
