import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

from backend.export import merge_turns, timestamp, write_exports
from backend.speakers import assign_speakers, uncovered
from backend.worker import split_interval


class SpeakerTests(unittest.TestCase):
    def test_three_speakers_keep_identity_across_blocks(self):
        rng = np.random.default_rng(7)
        rows = []
        voices = np.eye(3, 32, dtype=np.float32)
        # Порядок локальных номеров меняется в каждом блоке записи.
        sequence = [2, 0, 1, 0, 2, 1, 1, 2, 0] * 5
        for i, voice in enumerate(sequence):
            rows.append(dict(start=i * 4, end=i * 4 + 3, text="реплика",
                             embedding=(voices[voice] + rng.normal(0, .015, 32)).tolist()))
        count = assign_speakers(rows, count=3, anchor_limit=12)
        self.assertEqual(count, 3)
        mapping = {}
        for voice, row in zip(sequence, rows):
            mapping.setdefault(voice, row["speaker"])
            self.assertEqual(row["speaker"], mapping[voice])
        self.assertEqual(rows[0]["speaker"], 1)

    def test_auto_finds_two_distinct_voices(self):
        rows = [dict(start=i * 3, end=i * 3 + 2, text="реплика", embedding=v)
                for i, v in enumerate([[1, .01, 0], [0, 1, .01], [1, .02, 0], [.01, 1, 0]])]
        self.assertEqual(assign_speakers(rows), 2)
        self.assertEqual(rows[0]["speaker"], rows[2]["speaker"])

    def test_missing_voice_is_marked_uncertain(self):
        rows = [dict(start=0, end=2, text="угу", embedding=None)]
        self.assertEqual(assign_speakers(rows, 2), 1)
        self.assertTrue(rows[0]["uncertain"])

    def test_overlapping_intervals_do_not_make_false_gaps(self):
        self.assertEqual(uncovered([(3, 7), (5, 9), (12, 15)], 18), [(0, 3), (9, 12), (15, 18)])


class ExportTests(unittest.TestCase):
    def test_renaming_reaches_all_export_formats(self):
        doc = dict(source="Встреча.m4a", model="GigaAM", duration=10, names={}, segments=[
            dict(start=0, end=3, text="привет", speaker=1, overlap=True, uncertain=True),
            dict(start=2, end=5, text="ответ", speaker=2)])
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            write_exports(doc, folder, {"1": "Дмитрий", "2": "Юрий"})
            for suffix in ("txt", "md", "srt"):
                text = (folder / f"transcript.{suffix}").read_text()
                self.assertIn("Дмитрий", text)
                self.assertIn("Юрий", text)
                self.assertIn("[перекрытие]", text)
            saved = json.loads((folder / "Служебные данные" / "transcript.json").read_text())
            self.assertEqual(saved["names"]["2"], "Юрий")
            self.assertIn("00:00:00,000 --> 00:00:03,000", (folder / "transcript.srt").read_text())

    def test_plain_export_and_title(self):
        doc = dict(source="technical.m4a", title="Мой диалог", model="test", duration=12,
                   diarized=True, names={"1": "Дмитрий"},
                   segments=[dict(start=1, end=4, text="Текст", speaker=1, uncertain=True, overlap=True)])
        from backend.export import render
        text, subtitles = render(doc, include_speakers=False)
        self.assertIn("Мой диалог", text)
        self.assertIn("[00:00:01] Текст", text)
        self.assertNotIn("Дмитрий", text)
        self.assertNotIn("[?]", text)
        self.assertNotIn("перекрытие", text)
        self.assertNotIn("Дмитрий", subtitles)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            document = write_exports(doc, folder)
            self.assertEqual(document.parent.name, "Служебные данные")
            self.assertTrue((folder / "transcript.txt").is_file())

    def test_merge_preserves_overlap_and_speaker_switch(self):
        rows = [dict(start=0, end=2, text="один", speaker=1),
                dict(start=2, end=4, text="два", speaker=1),
                dict(start=3, end=5, text="вместе", speaker=2, overlap=True)]
        result = merge_turns(rows)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["text"], "один два")
        self.assertTrue(result[1]["overlap"])

    def test_time_rollover(self):
        self.assertEqual(timestamp(59.9999, True), "00:01:00,000")
        self.assertEqual(timestamp(3600), "01:00:00")

    def test_long_utterance_has_no_omissions_or_duplicate_ranges(self):
        samples = np.ones(70 * 16000, dtype=np.float32) * .1
        samples[24 * 16000:24 * 16000 + 320] = 0
        pieces = list(split_interval(0, 70, samples, 0))
        self.assertEqual(pieces[0][0], 0)
        self.assertEqual(pieces[-1][1], 70)
        for i, (start, end) in enumerate(pieces):
            self.assertLessEqual(end - start, 25)
            if i:
                self.assertEqual(start, pieces[i - 1][1])


if __name__ == "__main__":
    unittest.main()
