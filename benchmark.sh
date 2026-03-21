#!/bin/bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="results/benchmark_${TIMESTAMP}.log"
mkdir -p results

PROMPT="Write a Python implementation of merge sort with detailed comments explaining each step."

echo "===Benchmark with nthreads=4 ===" | tee -a $LOG
./dllama inference \
  --prompt "$PROMPT" \
  --steps 2048 \
  --model models/deepseek_r1_distill_llama_8b_q40/dllama_model_deepseek_r1_distill_llama_8b_q40.m \
  --tokenizer models/deepseek_r1_distill_llama_8b_q40/dllama_tokenizer_deepseek_r1_distill_llama_8b_q40.t \
  --buffer-float-type q80 \
  --nthreads 4 \
  --max-seq-len 4096 \
  --workers 192.168.111.51:9998 192.168.111.52:9998 192.168.111.53:9998 192.168.111.54:9998 192.168.111.55:9998 192.168.111.56:9998 192.168.111.57:9998 \
  2>/dev/null | tee -a $LOG
