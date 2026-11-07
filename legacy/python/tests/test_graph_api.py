"""Neighborhood graph API (todo 23).

Contract under test:

- ``GET /api/graph?seed={id}&depth={1|2}`` returns the SEED's neighborhood
  over the ``links`` table — never the whole corpus. Node/edge count is
  bounded by the hops (seed + 1-hop neighbors + 2-hop neighbors when
  ``depth=2``), and ``db._GRAPH_MAX_NODES`` caps pathological hubs.
- Response shape is ``{"nodes": [{id,title,url,tags,is_read,indegree}],
  "edges": [{source,target}]}``; edges are directed ``source -> target``
  (the [[wikilink]] direction) and only span nodes in the returned set.
- ``depth`` defaults to 1 and is validated to be exactly 1 or 2 (invalid →
  400). An unknown seed → 404. The route is authed by the global middleware
  (no exemption) → 401 without a session.
- An isolated seed yields a single-node graph with an empty edge list.
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from app import auth, db
from app.main import app

# The fixture graph (edge direction = source note's [[wikilink]] points at
# target):
#
#   X --links--> A --links--> B --links--> D --links--> E
#   A --links--> C
#   Y (isolated)
#
# Distances from seed A: B, C, X are 1 hop; D is 2 hops; E is 3 hops (A->B->
# D->E) and must NEVER appear at depth 2 — that is the "bounded by hops"
# assertion.


def _authed_client() -> TestClient:
    """A TestClient preloaded with a normal-scope session + csrf cookies."""
    sid = auth.create_session(scope="normal")
    csrf = db.get_conn().execute(
        "SELECT csrf_token FROM sessions WHERE id = ?", (sid,)
    ).fetchone()["csrf_token"]
    client = TestClient(app)
    client.cookies.set(auth.SESSION_COOKIE_NAME, sid)
    client.cookies.set("csrf_token", csrf)
    return client


def _fixture() -> dict[str, int]:
    """Seed the fixture graph; returns id-by-name."""
    names = ["Alpha Hub", "Beta Topic", "Gamma Topic", "Delta Topic", "Epsilon Far", "X Inlinker"]
    ids = {n: db.insert_bookmark(url=f"https://graph.example/{n.lower().replace(' ', '-')}", title=n) for n in names}
    hub, beta, delta, x = (ids[n] for n in names[:2] + names[3:4] + names[5:])
    db.update_bookmark(hub, note_body="see [[Beta Topic]] and [[Gamma Topic]] and [[X Inlinker]]")
    db.update_bookmark(beta, note_body="see [[Delta Topic]]")
    db.update_bookmark(delta, note_body="see [[Epsilon Far]]")
    db.update_bookmark(x, note_body="see [[Alpha Hub]]")
    # Y — isolated, no note, no links.
    ids["Y Isolated"] = db.insert_bookmark(
        url="https://graph.example/y-isolated", title="Y Isolated"
    )
    return ids


def _graph(client: TestClient, seed: int, depth: object = 1):
    params = {"seed": seed}
    if depth is not None:
        params["depth"] = depth
    return client.get("/api/graph", params=params)


# ---------------------------------------------------------------------------
# Neighborhood bounded by hops
# ---------------------------------------------------------------------------


def test_depth_1_returns_seed_plus_direct_neighbors_only(fresh_db):
    ids = _fixture()
    hub = ids["Alpha Hub"]
    client = _authed_client()
    with client:
        resp = _graph(client, hub, depth=1)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    node_ids = {n["id"] for n in body["nodes"]}
    # 1 hop in BOTH directions: B (out), C (out), X (in). D/E are 2+/3+ hops.
    assert node_ids == {hub, ids["Beta Topic"], ids["Gamma Topic"], ids["X Inlinker"]}
    edges = {(e["source"], e["target"]) for e in body["edges"]}
    # Hub's note links B, C AND X; X's note links hub back — so the hub<->X
    # pair is a two-way edge at depth 1.
    assert edges == {
        (hub, ids["Beta Topic"]),
        (hub, ids["Gamma Topic"]),
        (hub, ids["X Inlinker"]),
        (ids["X Inlinker"], hub),
    }


def test_depth_2_adds_second_hop_but_never_third(fresh_db):
    """D (2 hops via B->D) joins at depth 2; E is 3 hops and must stay out,
    and the D->E edge must not leak into the edge list."""
    ids = _fixture()
    hub = ids["Alpha Hub"]
    client = _authed_client()
    with client:
        resp = _graph(client, hub, depth=2)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    node_ids = {n["id"] for n in body["nodes"]}
    assert node_ids == {
        hub,
        ids["Beta Topic"],
        ids["Gamma Topic"],
        ids["X Inlinker"],
        ids["Delta Topic"],
    }
    edges = {(e["source"], e["target"]) for e in body["edges"]}
    assert edges == {
        (hub, ids["Beta Topic"]),
        (hub, ids["Gamma Topic"]),
        (hub, ids["X Inlinker"]),
        (ids["X Inlinker"], hub),
        (ids["Beta Topic"], ids["Delta Topic"]),
    }
    # Epsilon Far is 3 hops out and its D->E edge is outside the neighborhood.
    assert ids["Epsilon Far"] not in node_ids
    assert (ids["Delta Topic"], ids["Epsilon Far"]) not in edges


def test_depth_defaults_to_1(fresh_db):
    ids = _fixture()
    client = _authed_client()
    with client:
        resp = _graph(client, ids["Alpha Hub"], depth=None)

    assert resp.status_code == 200, resp.text
    assert len(resp.json()["nodes"]) == 4  # same as explicit depth=1


def test_edge_direction_is_source_to_target(fresh_db):
    """If A's note links B, the edge is {source: A, target: B}."""
    ids = _fixture()
    client = _authed_client()
    with client:
        body = _graph(client, ids["Alpha Hub"], depth=1).json()

    edge = next(
        e for e in body["edges"]
        if e["source"] == ids["Alpha Hub"] and e["target"] == ids["Beta Topic"]
    )
    assert edge == {"source": ids["Alpha Hub"], "target": ids["Beta Topic"]}


def test_node_shape_includes_tags_is_read_and_indegree(fresh_db):
    ids = _fixture()
    # Beta carries a tag; Gamma is left unread (default is_read=0).
    db.update_bookmark(ids["Beta Topic"], tags=["rust"])
    hub = ids["Alpha Hub"]
    client = _authed_client()
    with client:
        body = _graph(client, hub, depth=1).json()

    by_id = {n["id"]: n for n in body["nodes"]}
    beta = by_id[ids["Beta Topic"]]
    assert beta["title"] == "Beta Topic"
    assert beta["url"].startswith("https://graph.example/")
    assert beta["tags"] == ["rust"]
    assert beta["is_read"] == 0
    assert isinstance(beta["indegree"], int)
    # X links A, so A's indegree is 1 (a global count across the corpus).
    assert by_id[hub]["indegree"] == 1
    # B receives A->B.
    assert by_id[ids["Beta Topic"]]["indegree"] == 1


# ---------------------------------------------------------------------------
# Isolated seed, bounds, errors, auth
# ---------------------------------------------------------------------------


def test_isolated_seed_returns_single_node_graph(fresh_db):
    ids = _fixture()
    lonely = ids["Y Isolated"]
    client = _authed_client()
    with client:
        resp = _graph(client, lonely, depth=2)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert [n["id"] for n in body["nodes"]] == [lonely]
    assert body["edges"] == []


def test_hub_neighborhood_is_capped_at_graph_max_nodes(fresh_db, monkeypatch):
    """A pathological hub must never explode: the BFS truncates at
    db._GRAPH_MAX_NODES and every returned edge stays inside the node set."""
    monkeypatch.setattr(db, "_GRAPH_MAX_NODES", 10)
    hub = db.insert_bookmark(url="https://graph.example/hub", title="Hub")
    targets = [
        db.insert_bookmark(url=f"https://graph.example/target-{i:02d}", title=f"Target {i:02d}")
        for i in range(25)
    ]
    note = " ".join(f"[[Target {i:02d}]]" for i in range(25))
    db.update_bookmark(hub, note_body=note)
    assert len(targets) == 25

    client = _authed_client()
    with client:
        resp = _graph(client, hub, depth=2)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert len(body["nodes"]) == 10  # seed + 9 neighbors, cap enforced
    node_ids = {n["id"] for n in body["nodes"]}
    assert hub in node_ids
    for e in body["edges"]:
        assert e["source"] in node_ids and e["target"] in node_ids


def test_invalid_depth_returns_400(fresh_db):
    ids = _fixture()
    client = _authed_client()
    # Integer depths outside {1,2} are rejected 400; a non-integer is a
    # FastAPI query-param validation error (422) before the route runs.
    for bad in (0, 3, -1):
        with client:
            resp = _graph(client, ids["Alpha Hub"], depth=bad)
        assert resp.status_code == 400, f"depth={bad!r} -> {resp.status_code}"
    with client:
        resp = _graph(client, ids["Alpha Hub"], depth="deep")
    assert resp.status_code == 422


def test_unknown_seed_returns_404(fresh_db):
    client = _authed_client()
    with client:
        resp = _graph(client, 999999)
    assert resp.status_code == 404


def test_missing_seed_returns_422(fresh_db):
    client = _authed_client()
    with client:
        resp = client.get("/api/graph")
    assert resp.status_code == 422


def test_graph_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.get("/api/graph", params={"seed": 1})
    assert resp.status_code == 401


def test_graph_page_renders_and_404s_for_unknown_seed(fresh_db):
    ids = _fixture()
    client = _authed_client()
    with client:
        resp = client.get("/graph", params={"seed": ids["Alpha Hub"]}, headers={"Accept": "text/html"})
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert 'id="graph"' in resp.text
    assert "cytoscape" in resp.text

    with client:
        resp = client.get("/graph", params={"seed": 999999}, headers={"Accept": "text/html"})
    assert resp.status_code == 404


def test_graph_page_without_seed_shows_picker(fresh_db):
    client = _authed_client()
    with client:
        resp = client.get("/graph", headers={"Accept": "text/html"})
    assert resp.status_code == 200
    assert 'id="graph-seed-picker"' in resp.text
