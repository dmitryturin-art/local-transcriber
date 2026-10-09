"""Один проход ASR и привязка слов к голосам вместо повторов перекрывающихся клипов."""
from .speakers import normalize
import numpy as np


def union_intervals(intervals, join_gap=.25):
    result=[]
    for a,b in sorted(intervals):
        if b<=a: continue
        if result and a-result[-1][1]<=join_gap: result[-1]=(result[-1][0],max(result[-1][1],b))
        else: result.append((a,b))
    return result


def assign_words(words, turns):
    rows=[]
    for word in sorted(words,key=lambda z:z['start']):
        a,b=word['start'],max(word['end'],word['start']+.04)
        active=[z for z in turns if min(b,z['end'])-max(a,z['start'])>0]
        by_voice={}
        for turn in active:
            voice=turn.get('speaker')
            if voice is not None:
                by_voice[voice]=max(by_voice.get(voice,0),min(b,turn['end'])-max(a,turn['start']))
        overlap=len(by_voice)>1
        speaker=None;uncertain=True;embedding=None
        if len(by_voice)==1:
            speaker=next(iter(by_voice))
            source=max((z for z in active if z.get('speaker')==speaker),key=lambda z:z.get('similarity',0))
            uncertain=bool(source.get('uncertain'))
            embedding=source.get('embedding')
        elif len(by_voice)>1:
            ranked=sorted(by_voice,key=by_voice.get,reverse=True)
            # Только явное преобладание; при реальном наложении не угадываем человека.
            if by_voice[ranked[0]]>=2.5*by_voice[ranked[1]]: speaker=ranked[0]
        if speaker is None and not active:
            nearby=[z for z in turns if z.get('speaker') is not None and min(abs(z['end']-a),abs(z['start']-b))<.20]
            ids={z['speaker'] for z in nearby}
            if len(ids)==1: speaker=next(iter(ids))
        row=dict(start=a,end=b,text=word['text'],speaker=speaker,uncertain=uncertain,
                 overlap=overlap,embedding=embedding,language_warning=word.get('language_warning',False))
        if rows and speaker is not None and rows[-1].get('speaker') not in (None,speaker):
            previous=rows[-1]['text'].rstrip()
            token=word['text'].strip().strip('.,!?…').lower()
            # Короткое строчное слово в незавершённой фразе — ненадёжная граница
            # RNNT. Не присваиваем его другому человеку с ложной уверенностью.
            continuation=word['text'][:1].islower() and token not in {'да','нет','угу','ага','хм','ну','ок'}
            if previous and previous[-1] not in '.!?…' and continuation and b-a<.8:
                row['speaker']=None;row['uncertain']=True;speaker=None
        if rows and rows[-1].get('speaker')==speaker and a-rows[-1]['end']<.9 and b-rows[-1]['start']<60:
            previous=rows[-1]
            previous['text']+=' '+row['text'];previous['end']=max(previous['end'],b)
            previous['uncertain']=previous['uncertain'] or uncertain
            previous['overlap']=previous['overlap'] or overlap
            previous['language_warning']=previous['language_warning'] or row['language_warning']
            if embedding is not None:
                old=previous.get('embedding')
                previous['embedding']=normalize((np.asarray(old)+np.asarray(embedding))/2).tolist() if old is not None else embedding
        else:rows.append(row)
    return rows
