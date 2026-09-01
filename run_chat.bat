@echo off
cd /d D:\code\RAG
echo ====== RAG Chat (app_chat.py) ======
echo Starting Streamlit, opening http://localhost:8501 ...
call D:\Anaconda\Scripts\activate.bat rag
streamlit run app_chat.py --server.port 8501
pause