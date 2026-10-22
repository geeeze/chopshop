# chopshop-mock-runner — containerised mock of the chopshop-svg runner.
#
# Same HTTP contract as chopshop-svg:0.1.0 (/health, /jobs, /validations) so the
# studio can be driven without the real pipeline. It stays a SEPARATE image on
# purpose: a mock that shipped inside the svg image could not mock the svg image.
#
# What this fixes: the runner used to run from a host venv whose bin/python
# follows /usr/bin/python3, so a system Python upgrade made every installed
# package vanish with no error. The interpreter and its packages live in HERE
# now, so the host's Python is irrelevant to this service.
FROM python:3.14-slim

WORKDIR /app

# Deps first, so a source edit does not bust the layer cache.
COPY requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt

COPY runner.py ./

# Prove the image actually assembled, at BUILD time. The outage this prevents
# was 799 silent restarts of exactly this one import failing at RUNTIME.
RUN python -c "from PIL import Image, ImageDraw; import PIL; print('PIL', PIL.__version__, 'OK')"

ENV MOCK_PORT=8790 \
    MOCK_ROOT=/tmp/chopshop-mock \
    PYTHONUNBUFFERED=1

EXPOSE 8790
CMD ["python", "runner.py"]
