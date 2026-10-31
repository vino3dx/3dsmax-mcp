import json, sys
sys.path.insert(0, "test/max/_valley")
from maxcli import Bridge
path = sys.argv[1]
b = Bridge()
r = b.soft("execute_maxscript", code='fileIn @"%s"' % path)
print(json.dumps(r, ensure_ascii=False)[:4000])
b.close()
