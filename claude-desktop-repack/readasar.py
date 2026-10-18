import struct,json,sys
p=sys.argv[1]; name=sys.argv[2]
f=open(p,"rb")
_,_,_,hs=struct.unpack("<4I",f.read(16))
d=json.loads(f.read(hs))
base=16+hs
parts=name.split("/")
node=d
for part in parts:
    node=node["files"][part]
off=int(node["offset"])
f.seek(base+off)
sys.stdout.buffer.write(f.read(node["size"]))
