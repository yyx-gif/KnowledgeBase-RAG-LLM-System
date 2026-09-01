@echo off
cd /d D:\code\RAG
echo ====== RAG Upload (app_upload.py) ======
echo Starting Streamlit, opening http://localhost:8501 ...
call D:\Anaconda\Scripts\activate.bat rag
streamlit run app_upload.py --server.port 8501
pause