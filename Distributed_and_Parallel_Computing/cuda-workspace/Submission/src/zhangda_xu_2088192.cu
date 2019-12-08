// Name: Zhangda Xu
// Student ID: 2088192
//
// Assignment goals achieved:
//   - block scan
//   - full scan for large vectors
//   - bank conflict avoidance optimisation
//
// Time to execute the different scans on a vector of 10,000,000 entries:
//   - host scan without BCAO: 25539 ms
//   - Full scan without BCAO: 38.169792 ms
//   - Full scan with BCAO: 32.318272 ms
//
// CPU model: Intel Core i7-8750h
// GPU model: NVIDIA GTX 1050ti max-Q
//
//


#define MAX_BLOCK_SZ 1024
#define NUM_BANKS 32
#define LOG_NUM_BANKS 5

#ifdef ZERO_BANK_CONFLICTS
#define CONFLICT_FREE_OFFSET(n) \
	((n) >> NUM_BANKS + (n) >> (2 * LOG_NUM_BANKS))
#else
#define CONFLICT_FREE_OFFSET(n) ((n) >> LOG_NUM_BANKS)
#endif

#define EXTRA (CONFLICT_FREE_OFFSET((BLOCK_SIZE * 2 - 1))

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
// For the CUDA runtime routines (prefixed with "cuda_")
#include <cuda_runtime.h>

#include <helper_cuda.h>
#include <helper_functions.h>

// A helper macro to simplify handling cuda error checking
#define CUDA_ERROR( err, msg ) { \
if (err != cudaSuccess) {\
    printf( "%s: %s in %s at line %d\n", msg, cudaGetErrorString( err ), __FILE__, __LINE__);\
    exit( EXIT_FAILURE );\
}\
}

// scan.cuh
long host_scan(int* output, int* input, int length);
float blockscan(int *output, int *input, int length, bool bcao);
float scan(int *output, int *input, int length, bool bcao);

void scanLargeDeviceArray(int *output, int *input, int length, bool bcao);
void scanSmallDeviceArray(int *d_out, int *d_in, int length, bool bcao);
void scanLargeEvenDeviceArray(int *output, int *input, int length, bool bcao);


// kernels.cuh
__global__ void preScan_BCAO(int *output, int *input, int n, int powerOfTwo);
__global__ void preScan(int *output, int *input, int n, int powerOfTwo);

__global__ void prescan_large(int *output, int *input, int n, int* sums);
__global__ void preScan_large(int *output, int *input, int n, int *sums);

__global__ void add(int *output, int length, int *n1);
__global__ void add(int *output, int length, int *n1, int *n2);


// utils.h
void printResult(const char* prefix, int result, long nanoseconds);
void printResult(const char* prefix, int result, float milliseconds);

bool isPowerOfTwo(int x);
int nextPowerOfTwo(int x);

long get_nanos();

// main
#define SHARED_MEMORY_BANKS 32
#define LOG_MEM_BANKS 5

__global__ void preScan_BCAO(int *output, int *input, int n, int powerOfTwo)
{
	extern __shared__ int temp[];// allocated on invocation
	int thid = threadIdx.x;

	int ai = thid;
	int bi = thid + (n / 2);
	int bankOffsetA = CONFLICT_FREE_OFFSET(ai);
	int bankOffsetB = CONFLICT_FREE_OFFSET(bi);


	if (thid < n) {
		temp[ai + bankOffsetA] = input[ai];
		temp[bi + bankOffsetB] = input[bi];
	}
	else {
		temp[ai + bankOffsetA] = 0;
		temp[bi + bankOffsetB] = 0;
	}


	int offset = 1;
	for (int d = powerOfTwo >> 1; d > 0; d >>= 1) // build sum in place up the tree
	{
		__syncthreads();
		if (thid < d)
		{
			int ai = offset * (2 * thid + 1) - 1;
			int bi = offset * (2 * thid + 2) - 1;
			ai += CONFLICT_FREE_OFFSET(ai);
			bi += CONFLICT_FREE_OFFSET(bi);

			temp[bi] += temp[ai];
		}
		offset *= 2;
	}

	if (thid == 0) {
		temp[powerOfTwo - 1 + CONFLICT_FREE_OFFSET(powerOfTwo - 1)] = 0; // clear the last element
	}

	for (int d = 1; d < powerOfTwo; d *= 2) // traverse down tree & build scan
	{
		offset >>= 1;
		__syncthreads();
		if (thid < d)
		{
			int ai = offset * (2 * thid + 1) - 1;
			int bi = offset * (2 * thid + 2) - 1;
			ai += CONFLICT_FREE_OFFSET(ai);
			bi += CONFLICT_FREE_OFFSET(bi);

			int t = temp[ai];
			temp[ai] = temp[bi];
			temp[bi] += t;
		}
	}
	__syncthreads();

	if (thid < n) {
		output[ai] = temp[ai + bankOffsetA];
		output[bi] = temp[bi + bankOffsetB];
	}
}

__global__ void preScan(int *output, int *input, int n, int powerOfTwo) {
	extern __shared__ int temp[];// allocated on invocation
	int thid = threadIdx.x;

	if (thid < n) {
		temp[2 * thid] = input[2 * thid]; // load input into shared memory
		temp[2 * thid + 1] = input[2 * thid + 1];
	}
	else {
		temp[2 * thid] = 0;
		temp[2 * thid + 1] = 0;
	}


	int offset = 1;
	for (int d = powerOfTwo >> 1; d > 0; d >>= 1) // build sum in place up the tree
	{
		__syncthreads();
		if (thid < d)
		{
			int ai = offset * (2 * thid + 1) - 1;
			int bi = offset * (2 * thid + 2) - 1;
			temp[bi] += temp[ai];
		}
		offset *= 2;
	}

	if (thid == 0) { temp[powerOfTwo - 1] = 0; } // clear the last element

	for (int d = 1; d < powerOfTwo; d *= 2) // traverse down tree & build scan
	{
		offset >>= 1;
		__syncthreads();
		if (thid < d)
		{
			int ai = offset * (2 * thid + 1) - 1;
			int bi = offset * (2 * thid + 2) - 1;
			int t = temp[ai];
			temp[ai] = temp[bi];
			temp[bi] += t;
		}
	}
	__syncthreads();

	if (thid < n) {
		output[2 * thid] = temp[2 * thid]; // write results to device memory
		output[2 * thid + 1] = temp[2 * thid + 1];
	}
}


__global__ void prescan_large(int *output, int *input, int n, int *sums) {
	extern __shared__ int temp[];

	int bid = blockIdx.x;
	int thid = threadIdx.x;
	int blockOffset = bid * n;

	int ai = thid;
	int bi = thid + (n / 2);
	int bankOffsetA = CONFLICT_FREE_OFFSET(ai);
	int bankOffsetB = CONFLICT_FREE_OFFSET(bi);
	temp[ai + bankOffsetA] = input[blockOffset + ai];
	temp[bi + bankOffsetB] = input[blockOffset + bi];

	int offset = 1;
	for (int d = n >> 1; d > 0; d >>= 1) // build sum in place up the tree
	{
		__syncthreads();
		if (thid < d)
		{
			int ai = offset * (2 * thid + 1) - 1;
			int bi = offset * (2 * thid + 2) - 1;
			ai += CONFLICT_FREE_OFFSET(ai);
			bi += CONFLICT_FREE_OFFSET(bi);

			temp[bi] += temp[ai];
		}
		offset *= 2;
	}
	__syncthreads();


	if (thid == 0) {
		sums[bid] = temp[n - 1 + CONFLICT_FREE_OFFSET(n - 1)];
		temp[n - 1 + CONFLICT_FREE_OFFSET(n - 1)] = 0;
	}

	for (int d = 1; d < n; d *= 2) // traverse down tree & build scan
	{
		offset >>= 1;
		__syncthreads();
		if (thid < d)
		{
			int ai = offset * (2 * thid + 1) - 1;
			int bi = offset * (2 * thid + 2) - 1;
			ai += CONFLICT_FREE_OFFSET(ai);
			bi += CONFLICT_FREE_OFFSET(bi);

			int t = temp[ai];
			temp[ai] = temp[bi];
			temp[bi] += t;
		}
	}
	__syncthreads();

	output[blockOffset + ai] = temp[ai + bankOffsetA];
	output[blockOffset + bi] = temp[bi + bankOffsetB];
}

__global__ void preScan_large(int *output, int *input, int n, int *sums) {
	int bid = blockIdx.x;
	int thid = threadIdx.x;
	int blockOffset = bid * n;

	extern __shared__ int temp[];
	temp[2 * thid] = input[blockOffset + (2 * thid)];
	temp[2 * thid + 1] = input[blockOffset + (2 * thid) + 1];

	int offset = 1;
	for (int d = n >> 1; d > 0; d >>= 1) // build sum in place up the tree
	{
		__syncthreads();
		if (thid < d)
		{
			int ai = offset * (2 * thid + 1) - 1;
			int bi = offset * (2 * thid + 2) - 1;
			temp[bi] += temp[ai];
		}
		offset *= 2;
	}
	__syncthreads();


	if (thid == 0) {
		sums[bid] = temp[n - 1];
		temp[n - 1] = 0;
	}

	for (int d = 1; d < n; d *= 2) // traverse down tree & build scan
	{
		offset >>= 1;
		__syncthreads();
		if (thid < d)
		{
			int ai = offset * (2 * thid + 1) - 1;
			int bi = offset * (2 * thid + 2) - 1;
			int t = temp[ai];
			temp[ai] = temp[bi];
			temp[bi] += t;
		}
	}
	__syncthreads();

	output[blockOffset + (2 * thid)] = temp[2 * thid];
	output[blockOffset + (2 * thid) + 1] = temp[2 * thid + 1];
}


__global__ void add(int *output, int length, int *n) {
	int bid = blockIdx.x;
	int thid = threadIdx.x;
	int blockOffset = bid * length;

	output[blockOffset + thid] += n[bid];
}

__global__ void add(int *output, int length, int *n1, int *n2) {
	int bid = blockIdx.x;
	int thid = threadIdx.x;
	int blockOffset = bid * length;

	output[blockOffset + thid] += n1[bid] + n2[bid];
}


// test
void test(int N) {
	bool canBeBlockscanned = N <= 1024;

	time_t t;
	srand((unsigned)time(&t));
	int *in = new int[N];
	for (int i = 0; i < N; i++) {
		in[i] = rand() % 10;
	}

	printf("%i Elements \n", N);

	// sequential scan on CPU
	int *outHost = new int[N]();
	long time_host = host_scan(outHost, in, N);
	printResult("host    ", outHost[N - 1], time_host);

	// full scan
	int *outGPU = new int[N]();
	float time_gpu = scan(outGPU, in, N, false);
	printResult("gpu     ", outGPU[N - 1], time_gpu);

	// full scan with BCAO
	int *outGPU_bcao = new int[N]();
	float time_gpu_bcao = scan(outGPU_bcao, in, N, true);
	printResult("gpu bcao", outGPU_bcao[N - 1], time_gpu_bcao);

	if (canBeBlockscanned) {
		// basic level 1 block scan
		int *out_1block = new int[N]();
		float time_1block = blockscan(out_1block, in, N, false);
		printResult("level 1 ", out_1block[N - 1], time_1block);

		// level 1 block scan with BCAO
		int *out_1block_bcao = new int[N]();
		float time_1block_bcao = blockscan(out_1block_bcao, in, N, true);
		printResult("l1 bcao ", out_1block_bcao[N - 1], time_1block_bcao);

		delete[] out_1block;
		delete[] out_1block_bcao;
	}

	printf("\n");

	delete[] in;
	delete[] outHost;
	delete[] outGPU;
	delete[] outGPU_bcao;
}

int main()
{
	int TEN_MILLION = 10000000;

	int elements[] = {
		TEN_MILLION,
	};

	int numElements = sizeof(elements) / sizeof(elements[0]);

	for (int i = 0; i < numElements; i++) {
		test(elements[i]);
	}

	return 0;
}



// scan
#define checkCudaError(o, l) _checkCudaError(o, l, __func__)

int THREADS_PER_BLOCK = 512;
int ELEMENTS_PER_BLOCK = THREADS_PER_BLOCK * 2;

long host_scan(int* output, int* input, int length) {
	long start_time = get_nanos();

	output[0] = 0; // since this is a prescan, not a scan
	for (int j = 1; j < length; ++j)
	{
		output[j] = input[j - 1] + output[j - 1];
	}

	long end_time = get_nanos();
	return end_time - start_time;
}

float blockscan(int *output, int *input, int length, bool bcao) {
	int *d_out, *d_in;
	const int arraySize = length * sizeof(int);

	cudaMalloc((void **)&d_out, arraySize);
	cudaMalloc((void **)&d_in, arraySize);
	cudaMemcpy(d_out, output, arraySize, cudaMemcpyHostToDevice);
	cudaMemcpy(d_in, input, arraySize, cudaMemcpyHostToDevice);

	// start timer
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
	cudaEventRecord(start);

	int powerOfTwo = nextPowerOfTwo(length);
	if (bcao) {
		preScan_BCAO<<<1, (length + 1) / 2, 2 * powerOfTwo * sizeof(int)>>>(d_out, d_in, length, powerOfTwo);
	}
	else {
		preScan<<<1, (length + 1) / 2, 2 * powerOfTwo * sizeof(int)>>>(d_out, d_in, length, powerOfTwo);
	}

	// end timer
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	float elapsedTime = 0;
	cudaEventElapsedTime(&elapsedTime, start, stop);

	cudaMemcpy(output, d_out, arraySize, cudaMemcpyDeviceToHost);

	cudaFree(d_out);
	cudaFree(d_in);
	cudaEventDestroy(start);
	cudaEventDestroy(stop);

	return elapsedTime;
}

float scan(int *output, int *input, int length, bool bcao) {
	int *d_out, *d_in;
	const int arraySize = length * sizeof(int);

	cudaMalloc((void **)&d_out, arraySize);
	cudaMalloc((void **)&d_in, arraySize);
	cudaMemcpy(d_out, output, arraySize, cudaMemcpyHostToDevice);
	cudaMemcpy(d_in, input, arraySize, cudaMemcpyHostToDevice);

	// start timer
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
	cudaEventRecord(start);

	if (length > ELEMENTS_PER_BLOCK) {
		scanLargeDeviceArray(d_out, d_in, length, bcao);
	}
	else {
		scanSmallDeviceArray(d_out, d_in, length, bcao);
	}

	// end timer
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	float elapsedTime = 0;
	cudaEventElapsedTime(&elapsedTime, start, stop);

	cudaMemcpy(output, d_out, arraySize, cudaMemcpyDeviceToHost);

	cudaFree(d_out);
	cudaFree(d_in);
	cudaEventDestroy(start);
	cudaEventDestroy(stop);

	return elapsedTime;
}


void scanLargeDeviceArray(int *d_out, int *d_in, int length, bool bcao) {
	int remainder = length % (ELEMENTS_PER_BLOCK);
	if (remainder == 0) {
		scanLargeEvenDeviceArray(d_out, d_in, length, bcao);
	}
	else {
		// perform a large scan on a compatible multiple of elements
		int lengthMultiple = length - remainder;
		scanLargeEvenDeviceArray(d_out, d_in, lengthMultiple, bcao);

		// scan the remaining elements and add the (inclusive) last element of the large scan to this
		int *startOfOutputArray = &(d_out[lengthMultiple]);
		scanSmallDeviceArray(startOfOutputArray, &(d_in[lengthMultiple]), remainder, bcao);

		add<<<1, remainder>>>(startOfOutputArray, remainder, &(d_in[lengthMultiple - 1]), &(d_out[lengthMultiple - 1]));
	}
}

void scanSmallDeviceArray(int *d_out, int *d_in, int length, bool bcao) {
	int powerOfTwo = nextPowerOfTwo(length);

	if (bcao) {
		preScan_BCAO<<<1, (length + 1) / 2, 2 * powerOfTwo * sizeof(int)>>>(d_out, d_in, length, powerOfTwo);
	}
	else {
		preScan<<<1, (length + 1) / 2, 2 * powerOfTwo * sizeof(int)>>>(d_out, d_in, length, powerOfTwo);
	}
}

void scanLargeEvenDeviceArray(int *d_out, int *d_in, int length, bool bcao) {
	const int blocks = length / ELEMENTS_PER_BLOCK;
	const int sharedMemArraySize = ELEMENTS_PER_BLOCK * sizeof(int);

	int *d_sums, *d_incr;
	cudaMalloc((void **)&d_sums, blocks * sizeof(int));
	cudaMalloc((void **)&d_incr, blocks * sizeof(int));

	if (bcao) {
		prescan_large<<<blocks, THREADS_PER_BLOCK, 2 * sharedMemArraySize>>>(d_out, d_in, ELEMENTS_PER_BLOCK, d_sums);
	}
	else {
		preScan_large<<<blocks, THREADS_PER_BLOCK, 2 * sharedMemArraySize>>>(d_out, d_in, ELEMENTS_PER_BLOCK, d_sums);
	}

	const int sumsArrThreadsNeeded = (blocks + 1) / 2;
	if (sumsArrThreadsNeeded > THREADS_PER_BLOCK) {
		// perform a large scan on the sums arr
		scanLargeDeviceArray(d_incr, d_sums, blocks, bcao);
	}
	else {
		// only need one block to scan sums arr so can use small scan
		scanSmallDeviceArray(d_incr, d_sums, blocks, bcao);
	}

	add<<<blocks, ELEMENTS_PER_BLOCK>>>(d_out, ELEMENTS_PER_BLOCK, d_incr);

	cudaFree(d_sums);
	cudaFree(d_incr);
}



void printResult(const char* prefix, int result, long nanoseconds) {
	printf("  ");
	printf(prefix);
	printf(" : %i in %ld ms \n", result, nanoseconds / 1000);
}

void printResult(const char* prefix, int result, float milliseconds) {
	printf("  ");
	printf(prefix);
	printf(" : %i in %f ms \n", result, milliseconds);
}


bool isPowerOfTwo(int x) {
	return x && !(x & (x - 1));
}


int nextPowerOfTwo(int x) {
	int power = 1;
	while (power < x) {
		power *= 2;
	}
	return power;
}


long get_nanos() {
	struct timespec ts;
	timespec_get(&ts, TIME_UTC);
	return (long)ts.tv_sec * 1000000000L + ts.tv_nsec;
}