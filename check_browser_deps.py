import subprocess
try:
    result = subprocess.run(["apt-cache", "search", "chromium"], capture_output=True, text=True)
    print(result.stdout[:500])
except Exception as e:
    print(str(e))
