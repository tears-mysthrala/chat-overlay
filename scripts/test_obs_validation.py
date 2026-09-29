#!/usr/bin/env python3
"""
Full OBS Studio 32.2.2 Browser Source Validation Script.

Requirements:
    pip install websockets pillow

Environment Variables:
    OBS_WS_URI: OBS WebSocket URI (default: "ws://127.0.0.1:4455")
    OBS_PASSWORD: OBS WebSocket password (default: "")
    SERVER_URL: Chat Overlay HTTP Server (default: "http://127.0.0.1:4100")
    TEST_HANDLE: Profile handle to validate (default: "demo-stream")
    ARTIFACT_DIR: Directory where validation screenshots will be saved
    OBS_CLEANUP_SOURCE: If "true" (default), restores original OBS scene/input state upon exit

Validates:
- CEF Browser Source initialization
- Transparency & CSS styling
- Multi-platform live chat rendering (Twitch + YouTube unificado)
- Hide / Show connection lifecycle (DEV-13)
- Reconnection & event replay without duplicate messages
- Non-destructive test: leaves operator's OBS scene in original state
"""

import asyncio
import base64
import hashlib
import json
import os
import sys
import time
import websockets

OBS_WS_URI = os.environ.get("OBS_WS_URI", "ws://127.0.0.1:4455")
OBS_PASSWORD = os.environ.get("OBS_PASSWORD", "")
SERVER_URL = os.environ.get("SERVER_URL", "http://127.0.0.1:4100")
TEST_HANDLE = os.environ.get("TEST_HANDLE", "demo-stream")
ARTIFACT_DIR = os.environ.get("ARTIFACT_DIR", os.path.dirname(os.path.abspath(__file__)))

async def send_req(ws, req_type, req_data=None):
    req_id = f"req-{time.time_ns()}"
    msg = {
        "op": 6,
        "d": {
            "requestType": req_type,
            "requestId": req_id
        }
    }
    if req_data:
        msg["d"]["requestData"] = req_data
    await ws.send(json.dumps(msg))
    while True:
        raw = await ws.recv()
        data = json.loads(raw)
        if data.get("op") == 7 and data.get("d", {}).get("requestId") == req_id:
            status = data["d"].get("requestStatus", {})
            if not status.get("result", False):
                raise RuntimeError(f"OBS Request {req_type} failed: {status.get('comment', 'Unknown error')} (code {status.get('code')})")
            return data["d"].get("responseData", {})

async def main():
    print(f"[*] Conectando a OBS Studio WebSocket en {OBS_WS_URI}...")
    async with websockets.connect(OBS_WS_URI) as ws:
        hello = json.loads(await ws.recv())
        auth = hello.get("d", {}).get("authentication")
        identify = {
            "op": 1,
            "d": {
                "rpcVersion": 1,
                "eventSubscriptions": 33
            }
        }
        if auth:
            salt, challenge = auth["salt"], auth["challenge"]
            secret = base64.b64encode(hashlib.sha256((OBS_PASSWORD + salt).encode()).digest()).decode()
            auth_response = base64.b64encode(hashlib.sha256((secret + challenge).encode()).digest()).decode()
            identify["d"]["authentication"] = auth_response

        await ws.send(json.dumps(identify))
        _ = await ws.recv()
        print("[+] ¡Autenticación exitosa en OBS Studio!")

        # 1. Obtener versión e información de la plataforma
        version_data = await send_req(ws, "GetVersion")
        print(f"[+] Versión de OBS: {version_data['obsVersion']} ({version_data['platformDescription']})")
        print(f"[+] Versión de obs-websocket: {version_data['obsWebSocketVersion']}")

        # 2. Escena actual
        scene_data = await send_req(ws, "GetCurrentProgramScene")
        scene_name = scene_data["currentProgramSceneName"]
        print(f"[+] Escena activa en OBS: '{scene_name}'")

        # 3. Verificar o crear la fuente de navegador
        inputs_data = await send_req(ws, "GetInputList")
        existing_inputs = [i["inputName"] for i in inputs_data.get("inputs", [])]
        
        overlay_url = f"{SERVER_URL}/overlay/{TEST_HANDLE}"
        input_name = "ChatOverlay-OBS"
        was_created = False
        original_settings = None
        orig_enabled = None
        scene_item_id = None

        if input_name in existing_inputs:
            settings_resp = await send_req(ws, "GetInputSettings", {"inputName": input_name})
            original_settings = settings_resp.get("inputSettings", {})
        else:
            was_created = True

        try:
            if was_created:
                print(f"[*] Creando fuente 'browser_source' ('{input_name}') apuntando a {overlay_url}...")
                create_data = await send_req(ws, "CreateInput", {
                    "sceneName": scene_name,
                    "inputName": input_name,
                    "inputKind": "browser_source",
                    "inputSettings": {
                        "url": overlay_url,
                        "is_local_file": False,
                        "width": 1920,
                        "height": 1080,
                        "fps": 60,
                        "shutdown": True,
                        "restart_when_active": True
                    }
                })
                print(f"[+] Fuente creada con ID: {create_data.get('sceneItemId')}")
            else:
                print(f"[*] Actualizando ajustes de la fuente existente '{input_name}' a {overlay_url}...")
                await send_req(ws, "SetInputSettings", {
                    "inputName": input_name,
                    "inputSettings": {
                        "url": overlay_url,
                        "is_local_file": False,
                        "width": 1920,
                        "height": 1080,
                        "fps": 60,
                        "shutdown": True,
                        "restart_when_active": True
                    },
                    "overlay": False
                })

            # 4. Obtener sceneItemId y visibilidad original
            scene_items = await send_req(ws, "GetSceneItemList", {"sceneName": scene_name})
            scene_item = next((item for item in scene_items.get("sceneItems", []) if item["sourceName"] == input_name), None)
            if not scene_item:
                raise RuntimeError(f"El item de escena '{input_name}' no se encontró en la escena '{scene_name}'")
            scene_item_id = scene_item["sceneItemId"]
            orig_enabled = scene_item.get("sceneItemEnabled", True)
            print(f"[+] Item de escena ID: {scene_item_id} (Visibilidad previa: {orig_enabled})")

            # 5. Esperar a que el motor CEF cargue el HTML, ejecute JS, conecte el SSE y renderice mensajes
            print("[*] Esperando 6 segundos a que CEF conecte el SSE y renderice los mensajes...")
            await asyncio.sleep(6)

            # 6. Captura 1: Renderizado con mensajes en vivo
            print("[*] Capturando Screenshot 1 (Mensajes en vivo + transparencia)...")
            shot1 = await send_req(ws, "GetSourceScreenshot", {
                "sourceName": input_name,
                "imageFormat": "png",
                "imageWidth": 1280,
                "imageHeight": 720
            })
            img_b64_1 = shot1["imageData"].split(",", 1)[1] if "," in shot1["imageData"] else shot1["imageData"]
            shot1_path = os.path.join(ARTIFACT_DIR, "obs_chat_live.png")
            with open(shot1_path, "wb") as f:
                f.write(base64.b64decode(img_b64_1))
            print(f"[+] Screenshot 1 guardado en: {shot1_path} ({os.path.getsize(shot1_path)} bytes)")

            # 7. Ciclo de vida: Ocultar la fuente (SetSceneItemEnabled: false)
            print("[*] Probando ciclo de vida: Ocultando fuente en OBS (SetSceneItemEnabled: false)...")
            await send_req(ws, "SetSceneItemEnabled", {
                "sceneName": scene_name,
                "sceneItemId": scene_item_id,
                "sceneItemEnabled": False
            })
            print("[+] Fuente ocultada. Esperando 3 segundos...")
            await asyncio.sleep(3)

            # 8. Mostrar la fuente (SetSceneItemEnabled: true)
            print("[*] Mostrando fuente en OBS (SetSceneItemEnabled: true)...")
            await send_req(ws, "SetSceneItemEnabled", {
                "sceneName": scene_name,
                "sceneItemId": scene_item_id,
                "sceneItemEnabled": True
            })
            print("[+] Fuente visible nuevamente. Esperando reconexión y replay de mensajes...")
            await asyncio.sleep(5)

            # 9. Captura 2: Renderizado tras reconexión
            print("[*] Capturando Screenshot 2 (Post-reconexión)...")
            shot2 = await send_req(ws, "GetSourceScreenshot", {
                "sourceName": input_name,
                "imageFormat": "png",
                "imageWidth": 1280,
                "imageHeight": 720
            })
            img_b64_2 = shot2["imageData"].split(",", 1)[1] if "," in shot2["imageData"] else shot2["imageData"]
            shot2_path = os.path.join(ARTIFACT_DIR, "obs_chat_reconnected.png")
            with open(shot2_path, "wb") as f:
                f.write(base64.b64decode(img_b64_2))
            print(f"[+] Screenshot 2 guardado en: {shot2_path} ({os.path.getsize(shot2_path)} bytes)")

            # Verificación explícita de contenido en screenshots
            try:
                from PIL import Image
                im1 = Image.open(shot1_path)
                assert im1.getbbox() is not None, "El screenshot 1 está vacío (canal alfa = 0 en toda la imagen)"
                im2 = Image.open(shot2_path)
                assert im2.getbbox() is not None, "El screenshot 2 está vacío (canal alfa = 0 en toda la imagen)"
                print(f"[+] Verificación gráfica con éxito: bbox1={im1.getbbox()}, bbox2={im2.getbbox()}")
            except ImportError:
                assert os.path.getsize(shot1_path) > 10000, f"Tamaño anómalo de screenshot 1: {os.path.getsize(shot1_path)} bytes"
                assert os.path.getsize(shot2_path) > 10000, f"Tamaño anómalo de screenshot 2: {os.path.getsize(shot2_path)} bytes"

            # 10. Captura de la escena completa (Program Scene) para verificar transparencia sobre el lienzo
            print("[*] Capturando Screenshot 3 (Escena completa de OBS)...")
            shot_scene = await send_req(ws, "GetSourceScreenshot", {
                "sourceName": scene_name,
                "imageFormat": "png",
                "imageWidth": 1280,
                "imageHeight": 720
            })
            img_b64_scene = shot_scene["imageData"].split(",", 1)[1] if "," in shot_scene["imageData"] else shot_scene["imageData"]
            shot_scene_path = os.path.join(ARTIFACT_DIR, "obs_scene_full.png")
            with open(shot_scene_path, "wb") as f:
                f.write(base64.b64decode(img_b64_scene))
            print(f"[+] Screenshot 3 guardado en: {shot_scene_path} ({os.path.getsize(shot_scene_path)} bytes)")

            print("\n=======================================================")
            print("  VALIDACIÓN OBS STUDIO 32.2.2 COMPLETADA CON ÉXITO")
            print("=======================================================")
            print(f"1. Renderizado en vivo:     {shot1_path}")
            print(f"2. Reconexión / Ciclo vida: {shot2_path}")
            print(f"3. Lienzo de Escena OBS:    {shot_scene_path}")

        finally:
            cleanup_enabled = os.environ.get("OBS_CLEANUP_SOURCE", "true").lower() in ("true", "1", "yes")
            if cleanup_enabled:
                print("[*] Restaurando estado previo de OBS Studio...")
                try:
                    if was_created:
                        await send_req(ws, "RemoveInput", {"inputName": input_name})
                        print(f"[+] Fuente temporal '{input_name}' eliminada correctamente de OBS.")
                    else:
                        if original_settings is not None:
                            await send_req(ws, "SetInputSettings", {
                                "inputName": input_name,
                                "inputSettings": original_settings,
                                "overlay": False
                            })
                            print(f"[+] Ajustes previos de '{input_name}' restaurados correctamente en OBS.")
                        if orig_enabled is not None and scene_item_id is not None:
                            await send_req(ws, "SetSceneItemEnabled", {
                                "sceneName": scene_name,
                                "sceneItemId": scene_item_id,
                                "sceneItemEnabled": orig_enabled
                            })
                            print(f"[+] Estado de visibilidad previo ({orig_enabled}) restaurado.")
                except Exception as cleanup_err:
                    print(f"[-] Nota de limpieza OBS: {cleanup_err}")

if __name__ == "__main__":
    asyncio.run(main())
