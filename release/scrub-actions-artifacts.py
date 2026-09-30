#!/usr/bin/env python3
import io
import json
import os
import re
import sys
import urllib.request
import urllib.error
import zipfile

REPOSITORY = "coachedai/tailscale-repair-clean"
BRANCH = "work/3.0"
ENCODED_IPV4 = re.compile(rb"(?<![0-9])(?:[0-9]{1,3}\\\.){3}[0-9]{1,3}(?![0-9])")
TEXT_EXTENSIONS = {
    ".ps1",".psm1",".psd1",".cs",".vbs",".py",".json",".yml",".yaml",
    ".md",".txt",".xml",".config",".ini",".cfg",".conf",".toml",
    ".properties",".csv",".patch",".diff",".gitignore",".gitattributes"
}
MAX_ARTIFACT = 64 * 1024 * 1024
MAX_TOTAL = 1536 * 1024 * 1024
MAX_ENTRY = 16 * 1024 * 1024
MAX_DEPTH = 3

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def request(url, token, method="GET"):
    req=urllib.request.Request(url,method=method,headers={
        "Authorization":"Bearer "+token,
        "Accept":"application/vnd.github+json",
        "User-Agent":"TailscaleQuickRepair-ArtifactPrivacyScrub"
    })
    return urllib.request.urlopen(req,timeout=90)

def download_artifact(url, token):
    req=urllib.request.Request(url,headers={
        "Authorization":"Bearer "+token,
        "Accept":"application/vnd.github+json",
        "User-Agent":"TailscaleQuickRepair-ArtifactPrivacyScrub"
    })
    opener=urllib.request.build_opener(NoRedirect)
    try:
        response=opener.open(req,timeout=90)
        try:
            return response.read(MAX_ARTIFACT+1)
        finally:
            response.close()
    except urllib.error.HTTPError as e:
        if e.code not in (301,302,303,307,308):
            raise
        location=e.headers.get("Location")
        if not location or not location.startswith("https://"):
            raise RuntimeError("Artifact redirect was missing or not HTTPS")
        clean=urllib.request.Request(location,headers={"User-Agent":"TailscaleQuickRepair-ArtifactPrivacyScrub"})
        with urllib.request.urlopen(clean,timeout=90) as response:
            return response.read(MAX_ARTIFACT+1)

def api_json(url, token):
    with request(url,token) as r:
        return json.load(r)

def valid_encoded(data):
    for m in ENCODED_IPV4.finditer(data):
        raw=m.group(0).replace(b"\\.",b".")
        try:
            parts=[int(x) for x in raw.split(b".")]
        except Exception:
            continue
        if len(parts)==4 and all(0 <= x <= 255 for x in parts):
            value=b".".join(str(x).encode("ascii") for x in parts)
            if value not in {b"0.0.0.0",b"127.0.0.1",b"2.0.0.0",b"3.0.0.0"}:
                return True
    return False

def zip_contains_encoded(data, depth=0):
    if depth > MAX_DEPTH:
        raise RuntimeError("Nested artifact archive exceeded scan depth")
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for info in z.infolist():
            if info.is_dir():
                continue
            if info.file_size > MAX_ENTRY:
                continue
            name=info.filename.replace("\\","/")
            leaf=name.rsplit("/",1)[-1].lower()
            ext=os.path.splitext(leaf)[1]
            payload=z.read(info)
            if ext == ".zip":
                if zip_contains_encoded(payload,depth+1):
                    return True
            elif ext in TEXT_EXTENSIONS or leaf in {".gitignore",".gitattributes"}:
                if valid_encoded(payload):
                    return True
    return False

def main():
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY or os.environ.get("GITHUB_REF_NAME") != BRANCH:
        raise RuntimeError("Artifact scrub refused wrong repository or branch")
    token=os.environ.get("GH_TOKEN","")
    if not token:
        raise RuntimeError("Missing GitHub token")

    artifacts=[]
    page=1
    while True:
        data=api_json("https://api.github.com/repos/%s/actions/artifacts?per_page=100&page=%d"%(REPOSITORY,page),token)
        batch=data.get("artifacts",[])
        artifacts.extend(batch)
        if len(batch)<100:
            break
        page+=1
        if page>50:
            raise RuntimeError("Artifact pagination exceeded bound")

    scanned=deleted=expired=0
    total=0
    deleted_ids=[]
    for a in artifacts:
        if a.get("expired"):
            expired+=1
            continue
        aid=int(a["id"])
        size=int(a.get("size_in_bytes") or 0)
        if size<=0 or size>MAX_ARTIFACT:
            raise RuntimeError("Unexpired artifact outside bounded scan size: id=%d size=%d"%(aid,size))
        total+=size
        if total>MAX_TOTAL:
            raise RuntimeError("Artifact scan exceeded total byte bound")
        data=download_artifact("https://api.github.com/repos/%s/actions/artifacts/%d/zip"%(REPOSITORY,aid),token)
        if len(data)>MAX_ARTIFACT:
            raise RuntimeError("Artifact download exceeded byte bound")
        scanned+=1
        if zip_contains_encoded(data):
            with request("https://api.github.com/repos/%s/actions/artifacts/%d"%(REPOSITORY,aid),token,method="DELETE"):
                pass
            deleted+=1
            deleted_ids.append(aid)
            print("Deleted Tailscale Actions artifact id=%d name=%s after generic encoded-network match."%(aid,a.get("name","")))

    print("Artifact privacy scrub complete: scanned=%d deleted=%d expired_skipped=%d bytes=%d"%(scanned,deleted,expired,total))
    with open("artifact-privacy-scrub-result.json","w",encoding="utf-8") as f:
        json.dump({
            "schema":1,
            "repository":REPOSITORY,
            "scanned":scanned,
            "deleted":deleted,
            "expiredSkipped":expired,
            "deletedArtifactIds":deleted_ids,
            "scope":"Tailscale repository Actions artifacts only; generic encoded-network match; matched content never logged."
        },f,indent=2,sort_keys=True)
        f.write("\n")
    return 0

if __name__=="__main__":
    sys.exit(main())
