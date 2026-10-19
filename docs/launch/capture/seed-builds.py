import json, uuid, datetime, os
H=os.environ.get("DEMO_HOME", "/Users/Shared/you")
d=f"{H}/Library/Application Support/Container Desktop"; os.makedirs(d, exist_ok=True)
now=datetime.datetime.now(datetime.timezone.utc)
log=["#1 [internal] load build definition from Dockerfile","#1 DONE 0.0s","#2 [internal] load metadata for docker.io/library/python:3.11-slim","#2 DONE 1.2s","#3 [1/3] FROM docker.io/library/python:3.11-slim","#3 DONE 0.1s","#4 [2/3] RUN pip install --no-cache-dir fastapi uvicorn","#4 DONE 14.1s","#5 [3/3] COPY app.py /app.py","#5 DONE 0.0s","#6 exporting to image","#6 DONE 0.2s"]
recs=[]
for tag,ctx,plat,ago,dur,st in [
 ("acdemo-api:dev",f"{H}/src/acdemo",["linux/arm64","linux/amd64"],0.4,38,"succeeded"),
 ("acdemo-api:latest",f"{H}/src/acdemo",["linux/arm64"],3,21,"succeeded"),
 ("edge-agent:0.4.2",f"{H}/src/edge-agent",["linux/arm64","linux/amd64"],26,142,"succeeded"),
 ("edge-agent:0.4.1",f"{H}/src/edge-agent",["linux/arm64","linux/amd64"],50,97,"failed"),
 ("docs-site:preview",f"{H}/src/docs-site",["linux/arm64"],75,12,"cancelled"),
 ("acdemo-worker:dev",f"{H}/src/acdemo/worker",["linux/arm64"],98,33,"succeeded")]:
  s=now-datetime.timedelta(hours=ago)
  r={"id":str(uuid.uuid4()).upper(),"tag":tag,"contextDirectory":ctx,"platforms":plat,"startedAt":s.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "finishedAt":(s+datetime.timedelta(seconds=dur)).strftime("%Y-%m-%dT%H:%M:%SZ"),"status":st,"log":log if st=="succeeded" else log[:8]+(["ERROR: failed to solve: process \"/bin/sh -c go build ./...\" did not complete successfully: exit code: 1"] if st=="failed" else ["canceled"])}
  if st=="failed": r["errorMessage"]="process \"/bin/sh -c go build ./...\" did not complete successfully: exit code: 1"
  recs.append(r)
json.dump({"version":1,"records":recs}, open(f"{d}/builds.json","w"), indent=1)
