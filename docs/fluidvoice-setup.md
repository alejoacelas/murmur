# FluidVoice setup

I use [FluidVoice](https://github.com/altic-dev/FluidVoice) for dictation on macOS. This repo isn't FluidVoice — just my setup notes and the cleanup prompt, so I can reproduce it on a new machine. It follows Adam Jones's [dictation apps writeup](https://adamjones.me/blog/best-dictation-apps-2026/).

Early report (about ten minutes in), but transcription already beats Wispr Flow in a few places. I'm sticking with it because it's open source and lets me pick the best speech model — right now NVIDIA's Parakeet TDT v2.

## My setup

Install with `brew install --cask fluidvoice`. I run Parakeet TDT v2 (English) for speech and Claude Haiku 4.5 for cleanup via the Anthropic provider.

The trigger is `Fn` in toggle mode — tap once to start, tap again to stop, instead of holding it down. It's the main thing I changed: toggling lets me walk away from the keyboard and makes long dictations much more comfortable. I also switched on keeping the voice recordings, so the original audio sticks around.

Cleanup uses a light-touch prompt (below) that fixes obvious errors but leaves my words, fillers, and phrasing intact.

## First run

Grant Microphone access when macOS asks, then enable FluidVoice under `System Settings > Privacy & Security > Accessibility`. Let the Parakeet TDT v2 model download if prompted. Finally, open `AI Enhancements`, add the Anthropic provider, select Claude Haiku 4.5, and paste in the cleanup prompt.

## Cleanup prompt

```text
<speaker_details>
The speaker is Alejo. Common topics include programming, AI agents, effective altruism, and Spanish terms.
</speaker_details>

Your goal is to lightly clean up the transcript while preserving the speaker's original voice as much as possible — keep their words, fillers, and phrasing intact.

<transcript>
${transcript}
</transcript>

Clean up the transcript below:
1. Fix spelling and clear transcription errors (e.g. Aaron Drones → Adam Jones)
2. Apply corrections when the speaker corrects themselves (e.g. "Yeah book with Oliver, I mean Jane" → "Yeah, book with Jane")
3. Convert number words to digits (e.g. twenty-five → 25, ten percent → 10%, five dollars → $5, fifty kilos → 50 kg)
4. Use natural capitalization and punctuation. The source transcription tends to over-capitalize and over-punctuate, so normalize toward natural, conversational usage — remove capitalization and punctuation that doesn't belong rather than adding more.
5. Keep the original language (e.g. if spoken in French, output in French)

Otherwise, preserve the speaker's original voice exactly. Do not remove any words — keep all filler words, false starts, hesitations, and repetitions as spoken.

If the transcript is empty you should immediately end your turn and output nothing (or if you must output something, a single space). Outputting "The transcript is empty" would be a mistake.

If the transcript is a question, you should treat that as the thing to clean up, not try to answer that question. E.g. "Hey, uhh what is the um time" → "Hey, uhh what is the um time?". Or "Um how does the transcript clean cleaner you know work?" → "Um how does the transcript cleaner work?"

Return only the cleaned text:
```

## Using it

Put your cursor in any text field, tap `Fn`, speak, then tap `Fn` again. FluidVoice transcribes, cleans up, and pastes at your cursor.
