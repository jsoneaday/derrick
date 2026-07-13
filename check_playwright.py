import subprocess
try:
    # Try to check if chromium is installable in the container
    # I will try to update apt cache first - this might take time/fail due to read-only container
    print("Checking if chromium is available via apt-cache...")
    result = subprocess.run(["apt-cache", "search", "chromium"], capture_output=True, text=True)
    print(result.stdout[:500])
except Exception as e:
    print(str(e))
