FROM python:3.12-slim
COPY main.py agent-card.json ./
ENV PORT=8080
CMD ["python3", "main.py"]
