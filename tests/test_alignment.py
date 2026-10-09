import unittest
import numpy as np
from backend.alignment import assign_words, union_intervals
from backend.speakers import assign_speakers
from backend.worker import language_warning
from backend.export import render


class AlignmentTests(unittest.TestCase):
    def test_overlap_is_not_confidently_assigned(self):
        turns=[dict(start=0,end=3,speaker=1,uncertain=False),dict(start=2.8,end=5,speaker=2,uncertain=False)]
        words=[dict(start=.2,end=.5,text='Привет.'),dict(start=2.85,end=2.95,text='Вместе'),dict(start=3.5,end=4,text='Ответ.')]
        rows=assign_words(words,turns)
        self.assertEqual([r['speaker'] for r in rows],[1,None,2])
        self.assertTrue(rows[1]['overlap'])

    def test_duplicate_intervals_do_not_duplicate_words(self):
        self.assertEqual(union_intervals([(0,4),(2,5),(5.1,8)]),[(0,8)])

    def test_noise_singletons_do_not_create_eight_speakers(self):
        rng=np.random.default_rng(4);rows=[]
        for i in range(80):
            v=np.zeros(32);v[i%2]=1;v+=rng.normal(0,.01,32)
            rows.append(dict(start=i*4,end=i*4+3.5,text='test',embedding=v.tolist()))
        for i in range(6):
            v=np.zeros(32);v[5+i]=1
            rows.append(dict(start=400+i*4,end=403.5+i*4,text='noise',embedding=v.tolist(),recovered=True))
        self.assertEqual(assign_speakers(rows),2)

    def test_expected_language_does_not_rewrite_words(self):
        self.assertTrue(language_warning('yeah','ru'))
        self.assertFalse(language_warning('yeah','auto'))
        self.assertTrue(language_warning('Привет','en'))

    def test_plain_export_preserves_text_and_times(self):
        doc=dict(source='test',model='test',duration=5,diarized=True,names={'1':'Иван'},segments=[dict(start=1,end=2,text='Привет',speaker=1)])
        speaker,srt=render(doc);plain,plain_srt=render(doc,include_speakers=False)
        self.assertIn('Иван',speaker);self.assertNotIn('Иван',plain)
        self.assertIn('Привет',plain);self.assertIn('00:00:01,000 --> 00:00:02,000',plain_srt)


if __name__=='__main__':unittest.main()
