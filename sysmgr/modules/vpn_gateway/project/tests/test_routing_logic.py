from app.router_logic import match_route


def test_match_dynamic_buy_path():
    route = match_route("/buy/luboy-prefiks", [{"name": "buy", "match": "/buy/*", "upstream_pool": "cab"}])
    assert route["upstream_pool"] == "cab"


def test_match_default_route():
    route = match_route("/anything-else", [
        {"name": "buy", "match": "/buy/*", "upstream_pool": "cab"},
        {"name": "default", "match": "/*", "upstream_pool": "landing"},
    ])
    assert route["upstream_pool"] == "landing"
