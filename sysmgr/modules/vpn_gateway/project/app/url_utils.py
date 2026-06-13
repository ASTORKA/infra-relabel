from urllib.parse import urlencode, urlsplit, urlunsplit, parse_qsl


def merge_query(base_url: str, extra_query: str) -> str:
    if not extra_query:
        return base_url

    parts = urlsplit(base_url)
    current = dict(parse_qsl(parts.query, keep_blank_values=True))
    incoming = dict(parse_qsl(extra_query, keep_blank_values=True))
    current.update(incoming)
    merged = urlencode(current, doseq=True)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, merged, parts.fragment))
