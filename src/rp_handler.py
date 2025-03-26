import os
import time
import json
import base64
import urllib.request
import urllib.parse
import requests
from io import BytesIO
import runpod
from runpod.serverless.utils import rp_upload

# Time to wait between API check attempts in milliseconds
COMFY_API_AVAILABLE_INTERVAL_MS = 50
# Maximum number of API check attempts
COMFY_API_AVAILABLE_MAX_RETRIES = 500
# Time to wait between poll attempts in milliseconds
COMFY_POLLING_INTERVAL_MS = int(os.getenv("COMFY_POLLING_INTERVAL_MS", 250))
# Maximum number of poll attempts
COMFY_POLLING_MAX_RETRIES = int(os.getenv("COMFY_POLLING_MAX_RETRIES", 500))
# Host where ComfyUI is running
COMFY_HOST = "127.0.0.1:8188"
# Enforce a clean state after each job is done
REFRESH_WORKER = os.getenv("REFRESH_WORKER", "false").lower() == "true"

# Variables de connexion à Supabase
SUPABASE_URL = os.getenv("SUPABASE_URL", "default_value")
SUPABASE_API_KEY = os.getenv("SUPA_ROLE_TOKEN", "default_value")
SUPABASE_BUCKET = os.getenv("SUPABASE_BUCKET", "default_value")

def encode_video_to_base64(file_path):
    with open(file_path, "rb") as video_file:
        video_base64 = base64.b64encode(video_file.read()).decode('utf-8')
    return video_base64

def upload_to_supabase(video_base64, file_name):
    url = f"{SUPABASE_URL}/storage/v1/object/{SUPABASE_BUCKET}/{file_name}"
    
    headers = {
        "Authorization": f"Bearer {SUPABASE_API_KEY}",
        "Content-Type": "application/octet-stream",
    }
    
    response = requests.put(url, headers=headers, data=base64.b64decode(video_base64))

    if response.status_code == 200:
        print("Vidéo uploadée avec succès !")
        try:
            return response.json()
        except json.JSONDecodeError:
            return {"message": "Upload réussi mais pas de JSON retourné"}
    else:
        print(f"Erreur lors de l'upload : {response.status_code}, {response.text}")
        return {"error": response.text}

def validate_input(job_input):
    if job_input is None:
        return None, "Please provide input"

    if isinstance(job_input, str):
        try:
            job_input = json.loads(job_input)
        except json.JSONDecodeError:
            return None, "Invalid JSON format in input"

    workflow = job_input.get("workflow")
    if workflow is None:
        return None, "Missing 'workflow' parameter"

    images = job_input.get("images")
    if images is not None:
        if not isinstance(images, list) or not all(
            "name" in image and "image" in image for image in images
        ):
            return (
                None,
                "'images' must be a list of objects with 'name' and 'image' keys",
            )

    return {"workflow": workflow, "images": images}, None

def check_server(url, retries=500, delay=50):
    for i in range(retries):
        try:
            response = requests.get(url, timeout=2)
            if response.status_code == 200:
                print(f"runpod-worker-comfy - API is reachable")
                return True
        except requests.RequestException:
            pass
        time.sleep(delay / 1000)

    print(f"runpod-worker-comfy - Failed to connect to server at {url} after {retries} attempts.")
    return False

def upload_images(images):
    if not images:
        return {"status": "success", "message": "No images to upload", "details": []}

    responses = []
    upload_errors = []

    print(f"runpod-worker-comfy - image(s) upload")

    for image in images:
        name = image["name"]
        image_data = image["image"]
        blob = base64.b64decode(image_data)

        files = {
            "image": (name, BytesIO(blob), "image/png"),
            "overwrite": (None, "true"),
        }

        response = requests.post(f"http://{COMFY_HOST}/upload/image", files=files)
        if response.status_code != 200:
            upload_errors.append(f"Error uploading {name}: {response.text}")
        else:
            responses.append(f"Successfully uploaded {name}")

    if upload_errors:
        print(f"runpod-worker-comfy - image(s) upload with errors")
        return {
            "status": "error",
            "message": "Some images failed to upload",
            "details": upload_errors,
        }

    print(f"runpod-worker-comfy - image(s) upload complete")
    return {
        "status": "success",
        "message": "All images uploaded successfully",
        "details": responses,
    }

def queue_workflow(workflow):
    data = json.dumps({"prompt": workflow}).encode("utf-8")
    req = urllib.request.Request(f"http://{COMFY_HOST}/prompt", data=data)
    return json.loads(urllib.request.urlopen(req).read())

def get_history(prompt_id):
    with urllib.request.urlopen(f"http://{COMFY_HOST}/history/{prompt_id}") as response:
        return json.loads(response.read())

def base64_encode(img_path):
    with open(img_path, "rb") as image_file:
        encoded_string = base64.b64encode(image_file.read()).decode("utf-8")
        return f"{encoded_string}"

def process_output_images(outputs, job_id):
    COMFY_OUTPUT_PATH = os.environ.get("COMFY_OUTPUT_PATH", "/comfyui/output")
    output_images = {}

    for node_id, node_output in outputs.items():
        if "images" in node_output:
            for image in node_output["images"]:
                output_images = os.path.join(image["subfolder"], image["filename"])

    print(f"runpod-worker-comfy - image generation is done")

    local_image_path = f"{COMFY_OUTPUT_PATH}/{output_images}"
    print(f"runpod-worker-comfy - {local_image_path}")

    if os.path.exists(local_image_path):
        file_name = os.path.basename(output_images)

        if SUPABASE_URL and SUPABASE_API_KEY and SUPABASE_BUCKET:
            try:
                image = upload_to_supabase(base64_encode(local_image_path), file_name)
                print("runpod-worker-comfy - l'image a été générée et téléchargée sur Supabase")
            except Exception as e:
                print(f"runpod-worker-comfy - une erreur est survenue lors de l'upload sur Supabase: {str(e)}")
                return {
                    "status": "error",
                    "message": f"Erreur lors de l'upload sur Supabase: {str(e)}",
                }
        else:
            image = base64_encode(local_image_path)
            print("runpod-worker-comfy - l'image a été générée et convertie en base64")
    
        return {
            "status": "success",
            "message": image,
        }
    else:
        print(f"runpod-worker-comfy - l'image n'existe pas dans le dossier de sortie: {local_image_path}")
        return {
            "status": "error",
            "message": f"L'image n'existe pas dans le dossier spécifié: {local_image_path}",
        }

def handler(job):
    job_input = job["input"]

    validated_data, error_message = validate_input(job_input)
    if error_message:
        return {"error": error_message}

    workflow = validated_data["workflow"]
    images = validated_data.get("images")

    check_server(
        f"http://{COMFY_HOST}",
        COMFY_API_AVAILABLE_MAX_RETRIES,
        COMFY_API_AVAILABLE_INTERVAL_MS,
    )

    upload_result = upload_images(images)

    if upload_result["status"] == "error":
        return upload_result

    try:
        queued_workflow = queue_workflow(workflow)
        prompt_id = queued_workflow["prompt_id"]
        print(f"runpod-worker-comfy - queued workflow with ID {prompt_id}")
    except Exception as e:
        return {"error": f"Error queuing workflow: {str(e)}"}

    print(f"runpod-worker-comfy - wait until image generation is complete")
    retries = 0
    try:
        while retries < COMFY_POLLING_MAX_RETRIES:
            history = get_history(prompt_id)

            if prompt_id in history and history[prompt_id].get("outputs"):
                break
            else:
                time.sleep(COMFY_POLLING_INTERVAL_MS / 1000)
                retries += 1
        else:
            return {"error": "Max retries reached while waiting for image generation"}
    except Exception as e:
        return {"error": f"Error waiting for image generation: {str(e)}"}

    images_result = process_output_images(history[prompt_id].get("outputs"), job["id"])

    result = {**images_result, "refresh_worker": REFRESH_WORKER}
    return result

if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
