# Frees disk space during/after a repo sync: removes the .repo object stores of projects that are already checked out (never prebuilts/rust).
# usage: drop_objs.py <fox-tree> <manifest.xml> <path-prefix>      example: drop_objs.py ~/fox_12.1 effective_manifest.xml prebuilts/
# A tree whose object stores were removed is no longer a clean repo checkout: do not run `repo sync` on it again.
import sys, os, shutil, xml.etree.ElementTree as ET
root, manifest, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
freed=0
for p in ET.parse(manifest).getroot().iter("project"):
    name=p.get("name"); path=p.get("path") or name
    if not path.startswith(prefix) or path=="prebuilts/rust": continue
    wt=os.path.join(root,path)
    if not os.path.exists(os.path.join(wt,".git")): continue   # only finished projects
    for d in (os.path.join(root,".repo","projects",path+".git"),
              os.path.join(root,".repo","project-objects",name+".git")):
        if os.path.isdir(d):
            shutil.rmtree(d); print("removed", os.path.relpath(d,root))
