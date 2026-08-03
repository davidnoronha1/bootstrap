#!/usr/bin/env python3
import json
import os
from datetime import datetime, timedelta
import fcntl

cache_file = os.path.expanduser("~/.claude/cost_cache.json")
cache_ttl = 3600

def get_cached_cost():
    if not os.path.exists(cache_file):
        return None
    mtime = os.path.getmtime(cache_file)
    age = datetime.now().timestamp() - mtime
    if age > cache_ttl:
        return None
    try:
        with open(cache_file) as f:
            data = json.load(f)
        return data.get("day", 0), data.get("week", 0)
    except:
        return None

def set_cached_cost(day, week):
    os.makedirs(os.path.dirname(cache_file), exist_ok=True)
    try:
        with open(cache_file, 'w') as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            json.dump({"day": day, "week": week, "ts": datetime.now().timestamp()}, f)
    except:
        pass

cached = get_cached_cost()
if cached:
    print(cached[0], cached[1])
else:
    print("0 0")
    set_cached_cost(0, 0)