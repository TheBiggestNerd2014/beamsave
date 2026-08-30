import os
import zipfile

root = os.path.dirname(os.path.abspath(__file__))
version_path = os.path.join(root, "VERSION")
with open(version_path, "r", encoding="utf-8") as f:
    version = f.read().strip()
zip_path = os.path.join(root, "BeamSave_%s_BeamNG_0.39.zip" % version)

include_dirs = ("lua", "ui", "scripts")
include_files = ("README.md",)

with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for name in include_files:
        path = os.path.join(root, name)
        zf.write(path, name.replace("\\", "/"))
    for folder in include_dirs:
        base = os.path.join(root, folder)
        for dirpath, _, files in os.walk(base):
            for file in files:
                full = os.path.join(dirpath, file)
                rel = os.path.relpath(full, root).replace("\\", "/")
                zf.write(full, rel)

print("wrote", zip_path)
with zipfile.ZipFile(zip_path) as zf:
    for info in zf.infolist():
        print(info.filename)
