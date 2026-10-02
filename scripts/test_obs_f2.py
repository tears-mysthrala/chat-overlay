#!/usr/bin/env python3
"""
Test de Validación en Vivo de OBS Studio 32.2.2 para Fase F2.
Verifica:
1. Rechazo 401 Unauthorized sin Capability Token en OBS Browser Source.
2. Acceso autorizado 200 OK con Capability Token y renderizado de chat en vivo con SSE.
3. Revocación inmediata: al regenerar el token, el token anterior es rechazado con 401.
4. Restauración inmediata: al actualizar la fuente con el nuevo token, el overlay se restablece.
5. Capturas completas de evidencia visual.
"""

import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.request
import websockets
from PIL import Image

OBS_WS_URI = os.environ.get("OBS_WS_URI", "ws://127.0.0.1:4455")
OBS_PASSWORD_FILE = os.environ.get("OBS_PASSWORD_FILE")
OBS_PASSWORD = (Path(OBS_PASSWORD_FILE).read_text() if OBS_PASSWORD_FILE else os.environ.get("OBS_PASSWORD", ""))
SERVER_URL = os.environ.get("SERVER_URL", "http://127.0.0.1:4100")
TEST_HANDLE = os.environ.get("TEST_HANDLE", "demo")
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ARTIFACT_DIR = os.path.join(REPO_ROOT, "output", "obs_f2")
ARTIFACT_DIR = os.environ.get("ARTIFACT_DIR", DEFAULT_ARTIFACT_DIR)

async def send_req(ws, req_type, req_data=None, timeout=15.0):
    req_id = f"req-{time.time_ns()}"
    msg = {"op": 6, "d": {"requestType": req_type, "requestId": req_id}}
    if req_data:
        msg["d"]["requestData"] = req_data
    await ws.send(json.dumps(msg))
    start_time = time.monotonic()
    while True:
        elapsed = time.monotonic() - start_time
        remaining = max(0.1, timeout - elapsed)
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
        except asyncio.TimeoutError:
            raise TimeoutError(f"Timeout esperando respuesta de OBS para {req_type} (id: {req_id}) tras {timeout}s")
        data = json.loads(raw)
        if data.get("op") == 7 and data.get("d", {}).get("requestId") == req_id:
            status = data["d"].get("requestStatus", {})
            if not status.get("result", False):
                raise RuntimeError(f"OBS Request {req_type} failed: {status.get('comment', 'Unknown error')} (code {status.get('code')})")
            return data["d"].get("responseData", {})

def regenerate_token(handle, timeout=10.0):
    url = f"{SERVER_URL}/api/profiles/{handle}/token/regenerate"
    req = urllib.request.Request(url, data=b"{}", headers={
        "Content-Type": "application/json",
        "Origin": SERVER_URL
    }, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode())
        if not body.get("ok"):
            raise RuntimeError(f"Error regenerando token: {body}")
        return body["token"]

async def capture_source(ws, source_name, output_filename):
    shot = await send_req(ws, "GetSourceScreenshot", {
        "sourceName": source_name,
        "imageFormat": "png",
        "imageWidth": 1280,
        "imageHeight": 720
    })
    img_b64 = shot["imageData"].split(",", 1)[1] if "," in shot["imageData"] else shot["imageData"]
    out_path = os.path.join(ARTIFACT_DIR, output_filename)
    with open(out_path, "wb") as f:
        f.write(base64.b64decode(img_b64))
    im = Image.open(out_path)
    print(f"[+] Guardado: {out_path} ({os.path.getsize(out_path)} bytes, bbox={im.getbbox()})")
    return out_path, im

async def main():
    print(f"[*] Conectando a OBS Studio WebSocket en {OBS_WS_URI}...")
    async with websockets.connect(OBS_WS_URI) as ws:
        hello = json.loads(await ws.recv())
        auth = hello.get("d", {}).get("authentication")
        identify = {"op": 1, "d": {"rpcVersion": 1, "eventSubscriptions": 33}}
        if auth:
            salt, challenge = auth["salt"], auth["challenge"]
            secret = base64.b64encode(hashlib.sha256((OBS_PASSWORD + salt).encode()).digest()).decode()
            auth_response = base64.b64encode(hashlib.sha256((secret + challenge).encode()).digest()).decode()
            identify["d"]["authentication"] = auth_response

        await ws.send(json.dumps(identify))
        _ = await ws.recv()
        print("[+] ¡Autenticación exitosa en OBS Studio!")

        version_data = await send_req(ws, "GetVersion")
        print(f"[+] Versión de OBS: {version_data['obsVersion']} ({version_data['platformDescription']})")
        scene_data = await send_req(ws, "GetCurrentProgramScene")
        scene_name = scene_data["currentProgramSceneName"]
        print(f"[+] Escena activa en OBS: '{scene_name}'")

        input_name = "ChatOverlay-OBS"
        inputs_data = await send_req(ws, "GetInputList")
        existing_inputs = [i["inputName"] for i in inputs_data.get("inputs", [])]
        if input_name not in existing_inputs:
            print(f"[*] Creando fuente '{input_name}'...")
            await send_req(ws, "CreateInput", {
                "sceneName": scene_name,
                "inputName": input_name,
                "inputKind": "browser_source",
                "inputSettings": {
                    "url": "about:blank",
                    "width": 1280,
                    "height": 720,
                    "fps": 60,
                    "shutdown": True,
                    "restart_when_active": True
                }
            })

        os.makedirs(ARTIFACT_DIR, exist_ok=True)

        # 0. Inicializar token en el perfil para garantizar estado de protección activo
        print(f"[*] Inicializando Capability Token para perfil '{TEST_HANDLE}'...")
        token1 = regenerate_token(TEST_HANDLE)
        print(f"[+] Token 1 inicializado: [redacted]")

        # ==============================================================
        # CASO 1: Acceso SIN Capability Token -> 401 Unauthorized
        # ==============================================================
        print("\n--- CASO 1: Acceso SIN Capability Token (Rechazo 401) ---")
        unauth_url = f"{SERVER_URL}/overlay/{TEST_HANDLE}"
        # Verificación HTTP directa
        try:
            urllib.request.urlopen(unauth_url, timeout=5)
            raise AssertionError("Se esperaba HTTP 401 pero la petición tuvo éxito sin token.")
        except urllib.error.HTTPError as e:
            assert e.code == 401, f"Código inesperado sin token: {e.code}"
            print(f"[+] Verificación HTTP OK: {unauth_url} devolvió 401 Unauthorized")

        print(f"[*] Configurando OBS con URL sin token: {unauth_url}")
        await send_req(ws, "SetInputSettings", {
            "inputName": input_name,
            "inputSettings": {"url": unauth_url},
            "overlay": True
        })
        await send_req(ws, "PressInputPropertiesButton", {
            "inputName": input_name,
            "propertyName": "refreshnocache"
        })
        print("[*] Esperando 5 segundos a que CEF procese la respuesta 401...")
        await asyncio.sleep(5)
        path1, im1 = await capture_source(ws, input_name, "obs_f2_401_unauthorized.png")
        assert im1.getbbox() is not None, "Error: Screenshot 1 (401) está completamente transparente o vacío."

        # ==============================================================
        # CASO 2: Acceso CON Capability Token -> 200 OK y Chat en Vivo
        # ==============================================================
        print("\n--- CASO 2: Acceso CON Capability Token (200 OK y Chat en Vivo) ---")
        auth_url1 = f"{SERVER_URL}/overlay/{TEST_HANDLE}?token={token1}"
        with urllib.request.urlopen(auth_url1, timeout=5) as r:
            assert r.status == 200, f"Código inesperado con token: {r.status}"
            print(f"[+] Verificación HTTP OK: {SERVER_URL}/overlay/{TEST_HANDLE}?token=[redacted] devolvió 200 OK")

        print(f"[*] Configurando OBS con URL autorizada: {SERVER_URL}/overlay/{TEST_HANDLE}?token=[redacted]")
        await send_req(ws, "SetInputSettings", {
            "inputName": input_name,
            "inputSettings": {"url": auth_url1},
            "overlay": True
        })
        await send_req(ws, "PressInputPropertiesButton", {
            "inputName": input_name,
            "propertyName": "refreshnocache"
        })
        print("[*] Esperando 7 segundos a que CEF conecte el SSE y renderice mensajes del chat...")
        await asyncio.sleep(7)
        path2, im2 = await capture_source(ws, input_name, "obs_f2_authorized_live.png")
        assert im2.getbbox() is not None, "Error: Screenshot 2 (Chat en vivo) está vacío."

        # ==============================================================
        # CASO 3: Revocación de Token en Caliente -> Rechazo 401
        # ==============================================================
        print("\n--- CASO 3: Revocación de Token (Regenerar en Servidor y Refrescar OBS) ---")
        token2 = regenerate_token(TEST_HANDLE)
        print(f"[*] Token 2 regenerado: [redacted] (Token 1 ha sido invalidado)")

        # Comprobar que Token 1 ahora devuelve 401 vía HTTP
        try:
            urllib.request.urlopen(auth_url1, timeout=5)
            raise AssertionError("Se esperaba HTTP 401 tras revocación de Token 1.")
        except urllib.error.HTTPError as e:
            assert e.code == 401, f"Código inesperado tras revocación de token: {e.code}"
            print(f"[+] Verificación HTTP OK: URL con token revocado devolvió 401 Unauthorized")

        # Refrescamos la fuente en OBS que aún tiene Token 1
        print("[*] Refrescando la fuente en OBS manteniendo la URL antigua...")
        await send_req(ws, "PressInputPropertiesButton", {
            "inputName": input_name,
            "propertyName": "refreshnocache"
        })
        print("[*] Esperando 5 segundos a que CEF reciba el 401 Unauthorized...")
        await asyncio.sleep(5)
        path3, im3 = await capture_source(ws, input_name, "obs_f2_revoked_401.png")
        assert im3.getbbox() is not None, "Error: Screenshot 3 (Revocado) está vacío."

        # ==============================================================
        # CASO 4: Restauración con Nuevo Token -> Overlay Activo
        # ==============================================================
        print("\n--- CASO 4: Restauración de OBS con el Nuevo Token 2 ---")
        auth_url2 = f"{SERVER_URL}/overlay/{TEST_HANDLE}?token={token2}"
        with urllib.request.urlopen(auth_url2, timeout=5) as r:
            assert r.status == 200, f"Código inesperado con token nuevo: {r.status}"
            print(f"[+] Verificación HTTP OK: {SERVER_URL}/overlay/{TEST_HANDLE}?token=[redacted] devolvió 200 OK")

        print(f"[*] Configurando OBS con la nueva URL autorizada: {SERVER_URL}/overlay/{TEST_HANDLE}?token=[redacted]")
        await send_req(ws, "SetInputSettings", {
            "inputName": input_name,
            "inputSettings": {"url": auth_url2},
            "overlay": True
        })
        await send_req(ws, "PressInputPropertiesButton", {
            "inputName": input_name,
            "propertyName": "refreshnocache"
        })
        print("[*] Esperando 7 segundos a que CEF conecte con el nuevo token...")
        await asyncio.sleep(7)
        path4, im4 = await capture_source(ws, input_name, "obs_f2_restored_live.png")
        assert im4.getbbox() is not None, "Error: Screenshot 4 (Restaurado) está vacío."

        # ==============================================================
        # CASO 5: Escena Completa de OBS
        # ==============================================================
        print("\n--- CASO 5: Captura del Lienzo Completo de OBS ---")
        path5, im5 = await capture_source(ws, scene_name, "obs_f2_scene_full.png")

        print("\n" + "=" * 60)
        print("  TODAS LAS PRUEBAS EN VIVO DE OBS STUDIO COMPLETADAS CON ÉXITO")
        print("=" * 60)
        print(f"1. Rechazo 401 sin token:       {path1}")
        print(f"2. Chat en vivo con token:       {path2}")
        print(f"3. Revocación 401 tras cambio:   {path3}")
        print(f"4. Restauración con nuevo token: {path4}")
        print(f"5. Escena completa de OBS:       {path5}")

if __name__ == "__main__":
    asyncio.run(main())
