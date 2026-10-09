import numpy as np
from scipy.cluster.hierarchy import linkage, cut_tree
from scipy.spatial.distance import cdist


def normalize(v):
    v = np.asarray(v, dtype=np.float32)
    return v / max(float(np.linalg.norm(v)), 1e-9)


def choose_cluster_count(vectors, tree, maximum=8):
    """Сравниваем разделения по silhouette; одиночный шум не создаёт спикера."""
    n = len(vectors)
    if n < 4:
        return 1, []
    distances = np.clip(cdist(vectors, vectors, metric="cosine"), 0, 2)
    candidates = []
    for k in range(2, min(maximum, n // 2) + 1):
        labels = cut_tree(tree, n_clusters=[k]).ravel()
        sizes = np.bincount(labels)
        # У каждого найденного голоса должны быть несколько чистых реплик.
        if min(sizes) < max(2, int(np.ceil(n * .03))):
            continue
        means = np.stack([distances[:, labels == j].mean(axis=1) for j in range(k)], axis=1)
        scores = []
        for i, label in enumerate(labels):
            a = distances[i, labels == label].sum() / (sizes[label] - 1)
            b = np.min(np.delete(means[i], label))
            scores.append((b - a) / max(a, b, 1e-9))
        score = float(np.mean(scores))
        centroids = np.stack([normalize(vectors[labels == j].mean(axis=0)) for j in range(k)])
        separation = float(np.min(cdist(centroids, centroids, metric="cosine") + np.eye(k) * 10))
        candidates.append(dict(count=k, silhouette=round(score, 4), separation=round(separation, 4), sizes=sizes.tolist()))
    eligible = [z for z in candidates if z['silhouette'] >= .20 and z['separation'] >= .10]
    if not eligible:
        return 1, candidates
    best = max(eligible, key=lambda z: z['silhouette'] - .015 * (z['count'] - 2))
    return best['count'], candidates


def assign_speakers(rows, count=0, auto_distance=0.48, anchor_limit=1200, diagnostics=None):
    """Кластеризация по всей записи; объём матрицы ограничен 1200 образцами."""
    valid = [i for i, r in enumerate(rows) if r.get("embedding") is not None
             and np.isfinite(r['embedding']).all() and np.linalg.norm(r['embedding']) > 1e-6]
    if not valid:
        for row in rows:
            row.update(speaker=1, uncertain=True)
        return 1
    # Длинные и чистые реплики предпочтительнее междометий и наложений.
    anchors = [i for i in valid if rows[i]["end"] - rows[i]["start"] >= 3
               and not rows[i].get("overlap", False) and not rows[i].get('recovered', False)]
    if len(anchors) < max(4, count * 2):
        anchors = [i for i in valid if rows[i]['end'] - rows[i]['start'] >= 1.5 and not rows[i].get('overlap', False)]
    if len(anchors) < max(2, count):
        anchors = valid
    if len(anchors) > anchor_limit:
        anchors = [anchors[i] for i in np.linspace(0, len(anchors) - 1, anchor_limit, dtype=int)]
    vectors = np.stack([normalize(rows[i]["embedding"]) for i in anchors])
    if len(vectors) == 1:
        labels = np.zeros(1, dtype=int)
    else:
        tree = linkage(vectors.astype(np.float64), method="average", metric="cosine")
        if count:
            labels = cut_tree(tree, n_clusters=[min(count, len(vectors))]).reshape(-1)
        else:
            chosen, scores = choose_cluster_count(vectors, tree)
            labels = cut_tree(tree, n_clusters=[chosen]).reshape(-1)
            if diagnostics is not None:
                diagnostics.update(anchors=len(anchors), method='silhouette-with-support', candidates=scores, selected=chosen)
    centroids = np.stack([normalize(vectors[labels == k].mean(axis=0)) for k in sorted(set(labels))])
    assignments = {}
    for i in valid:
        scores = centroids @ normalize(rows[i]["embedding"])
        best = int(np.argmax(scores))
        margin = float(np.sort(scores)[-1] - np.sort(scores)[-2]) if len(scores) > 1 else 1.0
        assignments[i] = (best, float(scores[best]), margin)
    # Локальные номера из сегментации сохраняют одного говорящего в блоке.
    # Сопоставляем их по длинным чистым репликам, а не по каждому «угу» отдельно.
    votes = {}
    for i in anchors:
        key = rows[i].get('local_key')
        if key is None: continue
        cluster = assignments[i][0]
        weight = min(8, rows[i]['end']-rows[i]['start'])
        group = votes.setdefault(key, {})
        group[cluster] = group.get(cluster,0)+weight
    local_map = {}
    for key,group in votes.items():
        best=max(group,key=group.get)
        if group[best]/sum(group.values()) >= .8: local_map[key]=best
    for i in valid:
        key=rows[i].get('local_key');best,score,margin=assignments[i]
        if key in local_map and (rows[i]['end']-rows[i]['start']<1.5 or score<.4 or margin<.12):
            best=local_map[key]
            score=float(centroids[best] @ normalize(rows[i]['embedding']))
            assignments[i]=(best,score,margin)
    for i,row in enumerate(rows):
        if i not in assignments and row.get('local_key') in local_map:
            assignments[i]=(local_map[row['local_key']],0.0,0.0)
    # Нумерация в порядке первого появления, одинаковая во всех частях записи.
    order = {}
    previous = 1
    for i, row in enumerate(rows):
        if i in assignments:
            cluster, score, margin = assignments[i]
            if cluster not in order:
                order[cluster] = len(order) + 1
            previous = order[cluster]
            row.update(speaker=previous, similarity=round(score, 3),
                       uncertain=bool(score < .35 or margin < .10 or row.get("overlap")))
        else:
            row.update(speaker=None, uncertain=True)
    return len(order)


def uncovered(segments, duration, minimum=.7):
    """Промежутки, которые модель сегментации могла пропустить."""
    end = 0.0
    result = []
    for start, stop in sorted(segments):
        if start - end >= minimum:
            result.append((end, start))
        end = max(end, stop)
    if duration - end >= minimum:
        result.append((end, duration))
    return result
