import numpy as np
from scipy.cluster.hierarchy import linkage, cut_tree, fcluster


def normalize(v):
    v = np.asarray(v, dtype=np.float32)
    return v / max(float(np.linalg.norm(v)), 1e-9)


def assign_speakers(rows, count=0, auto_distance=0.48, anchor_limit=1200):
    """Кластеризация по всей записи; объём матрицы ограничен 1200 образцами."""
    valid = [i for i, r in enumerate(rows) if r.get("embedding") is not None]
    if not valid:
        for row in rows:
            row.update(speaker=1, uncertain=True)
        return 1
    # Длинные и чистые реплики предпочтительнее междометий и наложений.
    anchors = [i for i in valid if rows[i]["end"] - rows[i]["start"] >= 1.5
               and not rows[i].get("overlap", False)]
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
            labels = fcluster(tree, t=auto_distance, criterion="distance") - 1
            if len(set(labels)) > 8:
                labels = cut_tree(tree, n_clusters=[8]).reshape(-1)
    centroids = np.stack([normalize(vectors[labels == k].mean(axis=0)) for k in sorted(set(labels))])
    assignments = {}
    for i in valid:
        scores = centroids @ normalize(rows[i]["embedding"])
        best = int(np.argmax(scores))
        margin = float(np.sort(scores)[-1] - np.sort(scores)[-2]) if len(scores) > 1 else 1.0
        assignments[i] = (best, float(scores[best]), margin)
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
            row.update(speaker=previous, uncertain=True)
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
