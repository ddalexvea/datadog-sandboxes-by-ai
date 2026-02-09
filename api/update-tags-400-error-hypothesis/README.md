# OpenAPI vs Form-Data Validation Bug

## Problem

A mismatch between **OpenAPI schema validation** and **Flask's request handling** causes requests to fail when:

- The **OpenAPI schema** defines parameters as `in: query` (query string)
- The **frontend** sends parameters as `multipart/form-data` (request body)
- **Flask's `request.values`** would accept either, but OpenAPI validation rejects the request **before** Flask sees it

## Request Flow

```
                         REQUEST
                            │
                            ▼
┌─────────────────────────────────────────────────────┐
│          1. OpenAPI Validation (Connexion)          │
│                                                     │
│   • Checks parameters against schema                │
│   • If FAIL → 400 error (Flask never sees it)       │
│   • If PASS → continues to Flask                    │
└─────────────────────────────────────────────────────┘
                            │
                     (only if valid)
                            ▼
┌─────────────────────────────────────────────────────┐
│              2. Flask Handler                       │
│                                                     │
│   • Business logic                                  │
│   • Returns response                                │
└─────────────────────────────────────────────────────┘
```

## Real-World Example (Datadog)

This reproduces an issue found in Infrastructure Map vs Host List:

| UI Component | How it sends `host_alias` | Result |
|--------------|---------------------------|--------|
| **Host List** | Query string (`?host_alias=xxx`) | ✅ Works |
| **Infrastructure Map** | Form-data body | ❌ 400 Error |

Error from production:
```json
{"status":"400","title":"Missing Parameter","detail":"missing parameter \"host_alias\" in \"query\""}
```

---

## Quick Start (Minikube)

### 1. Create the directory

```bash
mkdir -p openapi-formdata-bug && cd openapi-formdata-bug
```

### 2. Create requirements.txt

```bash
cat > requirements.txt << 'EOF'
flask==3.0.0
connexion[flask,swagger-ui,uvicorn]==3.0.5
EOF
```

### 3. Create app.py

```bash
cat > app.py << 'EOF'
from flask import Flask, request, jsonify
import connexion

# Connexion = OpenAPI validation + Flask combined
app = connexion.FlaskApp(__name__, specification_dir='./')
app.add_api('openapi.yaml', validate_responses=True)
flask_app = app.app

# Direct Flask endpoint (no OpenAPI validation)
@flask_app.route('/direct/update_tags', methods=['POST'])
def direct_update_tags():
    host_alias = request.values.get('host_alias')
    user_tags = request.values.get('user_tags', '')
    if not host_alias:
        return jsonify({"error": "Missing host_alias parameter"}), 400
    return jsonify({
        "message": "Success (direct Flask - no OpenAPI)",
        "source": "request.values (query OR form-data)",
        "host_alias": host_alias,
        "user_tags": user_tags
    })

# OpenAPI-validated endpoint handler
def update_tags(host_alias, user_tags=None):
    return {
        "message": "Success (OpenAPI validated)",
        "source": "query params only (per OpenAPI spec)",
        "host_alias": host_alias,
        "user_tags": user_tags or ""
    }

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF
```

### 4. Create openapi.yaml

```bash
cat > openapi.yaml << 'EOF'
openapi: 3.0.0
info:
  title: OpenAPI Form-Data Bug Reproduction
  version: 1.0.0
paths:
  /source/update_tags:
    post:
      operationId: app.update_tags
      summary: Update host tags (OpenAPI validated)
      parameters:
        - name: host_alias
          in: query
          required: true
          schema:
            type: string
        - name: user_tags
          in: query
          required: false
          schema:
            type: string
      requestBody:
        required: false
        content:
          application/json:
            schema:
              type: object
      responses:
        '200':
          description: Success
        '400':
          description: Bad Request
EOF
```

### 5. Create Dockerfile

```bash
cat > Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py openapi.yaml ./
EXPOSE 5000
CMD ["python", "app.py"]
EOF
```

### 6. Create deployment.yaml

```bash
cat > deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openapi-bug-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openapi-bug-demo
  template:
    metadata:
      labels:
        app: openapi-bug-demo
    spec:
      containers:
      - name: app
        image: openapi-bug-demo:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 5000
---
apiVersion: v1
kind: Service
metadata:
  name: openapi-bug-demo
spec:
  type: NodePort
  selector:
    app: openapi-bug-demo
  ports:
  - port: 5000
    targetPort: 5000
    nodePort: 30500
EOF
```

### 7. Build & Deploy

```bash
eval $(minikube docker-env)
docker build -t openapi-bug-demo:latest .
kubectl apply -f deployment.yaml
kubectl wait --for=condition=ready pod -l app=openapi-bug-demo --timeout=60s
```

### 8. Port-forward & Test

```bash
kubectl port-forward svc/openapi-bug-demo 5000:5000 &
sleep 3

# TEST 1: OpenAPI + Query Params (✅ Works)
curl -s -X POST 'http://localhost:5000/source/update_tags?host_alias=minikube&user_tags=env:test' \
  -H "Content-Type: application/json" -d '{}'

# TEST 2: OpenAPI + Form-Data (❌ 400 Error)
curl -s -X POST 'http://localhost:5000/source/update_tags' \
  --form "host_alias=minikube" --form "user_tags=env:test"

# TEST 3: Direct Flask + Query Params (✅ Works)
curl -s -X POST 'http://localhost:5000/direct/update_tags?host_alias=minikube&user_tags=env:test'

# TEST 4: Direct Flask + Form-Data (✅ Works)
curl -s -X POST 'http://localhost:5000/direct/update_tags' \
  --form "host_alias=minikube" --form "user_tags=env:test"
```

### 9. Cleanup

```bash
kubectl delete -f deployment.yaml
```

---

## Test Results

### TEST 1: OpenAPI endpoint + Query Params ✅

```bash
curl -X POST 'http://localhost:5000/source/update_tags?host_alias=minikube&user_tags=env:test' \
  -H "Content-Type: application/json" -d '{}'
```

```json
{
  "host_alias": "minikube",
  "message": "Success (OpenAPI validated)",
  "source": "query params only (per OpenAPI spec)",
  "user_tags": "env:test"
}
```

### TEST 2: OpenAPI endpoint + Form-Data ❌

```bash
curl -X POST 'http://localhost:5000/source/update_tags' \
  --form "host_alias=minikube" --form "user_tags=env:test"
```

```json
{"type": "about:blank", "title": "Bad Request", "detail": "Missing query parameter 'host_alias'", "status": 400}
```

### TEST 3: Direct Flask + Query Params ✅

```bash
curl -X POST 'http://localhost:5000/direct/update_tags?host_alias=minikube&user_tags=env:test'
```

```json
{
  "host_alias": "minikube",
  "message": "Success (direct Flask - no OpenAPI)",
  "source": "request.values (query OR form-data)",
  "user_tags": "env:test"
}
```

### TEST 4: Direct Flask + Form-Data ✅

```bash
curl -X POST 'http://localhost:5000/direct/update_tags' \
  --form "host_alias=minikube" --form "user_tags=env:test"
```

```json
{
  "host_alias": "minikube",
  "message": "Success (direct Flask - no OpenAPI)",
  "source": "request.values (query OR form-data)",
  "user_tags": "env:test"
}
```

---

## Summary

```
┌─────────────────────┬──────────────┬─────────────┐
│ Endpoint            │ Query Params │ Form-Data   │
├─────────────────────┼──────────────┼─────────────┤
│ /source/update_tags │ ✅ Works     │ ❌ Rejected │
│ (OpenAPI validated) │              │             │
├─────────────────────┼──────────────┼─────────────┤
│ /direct/update_tags │ ✅ Works     │ ✅ Works    │
│ (Flask only)        │              │             │
└─────────────────────┴──────────────┴─────────────┘
```

---

## Root Cause

```
Frontend sends:
  POST /source/update_tags
  Content-Type: multipart/form-data
  Body: { host_alias: "minikube", user_tags: "env:test" }
         │
         ▼
┌─────────────────────────────────────┐
│     OpenAPI Validation Layer        │  ❌ REJECTED!
│                                     │
│  Schema says: host_alias in: query  │
│  Request has: host_alias in: body   │
└─────────────────────────────────────┘
         │
         ✖ Request never reaches Flask
         ▼
┌─────────────────────────────────────┐
│     Flask Endpoint                  │  Would accept it!
│                                     │
│  request.values.get("host_alias")   │
│  (accepts query OR form-data)       │
└─────────────────────────────────────┘
```

---

## Fix Options

### Option 1: Fix Frontend (Recommended)

Change the frontend to send `host_alias` as a query parameter:

```typescript
// Before (broken - Infrastructure Map)
HttpPOST('/source/update_tags', { type: 'formdata' })({ host_alias, user_tags });

// After (working - like Host List)
HttpPOST(`/source/update_tags?host_alias=${host_alias}&user_tags=${user_tags}`)({});
```

### Option 2: Update OpenAPI Schema ✅ TESTED

Change the schema to accept parameters in the request body:

```yaml
# Before (current)
parameters:
  - name: host_alias
    in: query  # ❌ Only accepts query params

# After (accepts form-data)
requestBody:
  required: true
  content:
    multipart/form-data:
      schema:
        type: object
        required:
          - host_alias
        properties:
          host_alias:
            type: string
          user_tags:
            type: string
```

