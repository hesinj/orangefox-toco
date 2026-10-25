# Lists the projects of a repo manifest by size and state (checked out or not). usage: inventory.py <fox-tree> <manifest.xml>   (manifest: .repo/manifests/*.xml or the effective manifest from `repo manifest -o`)
import sys, os, re, subprocess, xml.etree.ElementTree as ET
root = sys.argv[1]
t = ET.parse(sys.argv[2]).getroot()
def du(p):
    if not os.path.exists(p): return 0
    r = subprocess.run(["du","-sk",p],capture_output=True,text=True)
    return int(r.stdout.split()[0]) if r.stdout else 0
rows=[]
for p in t.iter("project"):
    name=p.get("name"); path=p.get("path") or name
    wt=os.path.join(root,path)
    has_wt=os.path.exists(os.path.join(wt,".git"))
    objs=os.path.join(root,".repo","project-objects",name+".git")
    proj=os.path.join(root,".repo","projects",path+".git")
    rows.append((du(wt) if has_wt else 0, du(objs), has_wt, os.path.exists(proj), path, name))
rows.sort(reverse=True)
print("worktree_MB objs_MB checkedout path")
for w,o,h,pr,path,name in rows[:30]: print(f"{w//1024:8d} {o//1024:7d} {str(h):5} {path}")
print("projects total:",len(rows),"| with worktree:",sum(1 for r in rows if r[2]),"| missing worktree:",sum(1 for r in rows if not r[2]))
print("MISSING:", [r[4] for r in rows if not r[2]])
print("total worktree GB: %.1f  total objs GB: %.1f" % (sum(r[0] for r in rows)/1048576, sum(r[1] for r in rows)/1048576))
