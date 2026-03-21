#include <cstdio>
#include <ctime>
#include <sched.h>
#include <sys/resource.h>

// Returns monotonic time in microseconds
static inline long long diagNowUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000LL + ts.tv_nsec / 1000;
}

// Returns wall-clock timestamp string, written into buf (at least 16 bytes)
static inline void diagTimestamp(char *buf, int bufLen) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm *tm_info = localtime(&ts.tv_sec);
    int ms = (int)(ts.tv_nsec / 1000000);
    snprintf(buf, bufLen, "%02d:%02d:%02d.%03d",
        tm_info->tm_hour, tm_info->tm_min, tm_info->tm_sec, ms);
}

// Returns current process RSS in KB
static inline long diagMemKb() {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_maxrss;
}

struct DiagState {
    NnUint prevEvalTime = 0;
    NnUint prevSyncTime = 0;
    NnUint prevPredExec = 0;
    NnUint prevPredSync = 0; 
    long long tokenStartUs = 0;

    void reset() {
        prevEvalTime = prevSyncTime = 0;
        prevPredExec = prevPredSync = 0;
        tokenStartUs = diagNowUs();
    }
    void resetPerToken(){
    	prevPredExec = 0;
	prevPredSync = 0; 
	prevEvalTime = 0;
	prevSyncTime = 0;
    }

    // Call after getTotalTime() to get per-token deltas
    void printEval(NnUint evalTime, NnUint syncTime,
                   int numWorkers, NnSize sentBytes, NnSize recvBytes,
                   int batchSize)
    {
        char ts[16];
        diagTimestamp(ts, sizeof(ts));

        NnUint dEval = evalTime - prevEvalTime;
        NnUint dSync = syncTime - prevSyncTime;
        long long wallUs = diagNowUs() - tokenStartUs;
        int core = sched_getcpu();
        long memKb = diagMemKb();

        printf("🔷️ [%s] Eval %5u ms Sync %5u ms | Wall %5lld ms | Core %2d | Mem %7ld KB | Workers %d | Sent %6zu kB Recv %6zu kB | (%d tokens)%s\n",
            ts,
            dEval / 1000,
            dSync / 1000,
            wallUs / 1000,
            core,
            memKb,
            numWorkers,
            sentBytes / 1024,
            recvBytes / 1024,
            batchSize,
            dSync > 500000 ? " ⚠️  SYNC SPIKE" : "");  // flag spikes > 500ms

        tokenStartUs = diagNowUs();
    }

    void printPred(NnUint predTime, NnUint syncTime,
                   int numWorkers, NnSize sentBytes, NnSize recvBytes,
                   const char *piece)
    {
        char ts[16];
        diagTimestamp(ts, sizeof(ts));

        NnUint dPred = predTime - prevPredExec;
        NnUint dSync = syncTime - prevPredSync;
	prevPredExec = predTime; 
	prevPredSync = syncTime; 
        long long wallUs = diagNowUs() - tokenStartUs;
        int core = sched_getcpu();
        long memKb = diagMemKb();

        printf("🔶 [%s] Pred %5ums Sync %5ums | Wall %5lldms | Core %2d | Mem %7ldKB | Workers %d | Sent %6zukB Recv %6zukB | %s%s\n",
            ts,
            dPred / 1000,
            dSync / 1000,
            wallUs / 1000,
            core,
            memKb,
            numWorkers,
            sentBytes / 1024,
            recvBytes / 1024,
            piece == nullptr ? "~" : piece,
            dSync > 500000 ? " ⚠️  SYNC SPIKE" : "");

        prevEvalTime = predTime;
        prevSyncTime = syncTime;
        tokenStartUs = diagNowUs();
    }
};
