from app.config import load_config


def test_load_config_has_dynamic_buy_route():
    cfg = load_config("config/gateway.yml")
    buy_route = next(r for r in cfg.routing.routes if r.name == "buy-any")
    assert buy_route.match == "/buy/*"
    assert buy_route.upstream_pool == "cabinet_pool"


def test_no_hardcoded_buy_prefixes_in_config_targets():
    cfg = load_config("config/gateway.yml")
    for target in cfg.upstreams["cabinet_pool"].targets:
        assert "/buy/wl-lte" not in target


def test_landing_mirror_mode_enabled():
    cfg = load_config("config/gateway.yml")
    assert cfg.raw["landing"]["mode"] == "mirror_redirect"
    assert cfg.raw["landing"]["pages"][0]["mirror_target"] == "wl-lte"
