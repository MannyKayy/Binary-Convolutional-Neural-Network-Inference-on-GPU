#include <iostream>
#include <stdlib.h>
#include <fstream>
#include <sstream>
#include <utility>
#include <unordered_map>
#include <cuda.h>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <chrono>
#include <vector>
#include <assert.h>
#include <math.h>

#define NUM_STREAMS 2

struct GPUTimer
{
    GPUTimer() 
    {
        cudaEventCreate(&start_);
        cudaEventCreate(&stop_);
        cudaEventRecord(start_, 0);
    }

    ~GPUTimer() 
    {
        cudaEventDestroy(start_);
        cudaEventDestroy(stop_);
    }

    void start() 
    {
        cudaEventRecord(start_, 0);
    }

    float seconds() 
    {
        cudaEventRecord(stop_, 0);
        cudaEventSynchronize(stop_);
        float time;
        cudaEventElapsedTime(&time, start_, stop_);
        return time * 1e-3;
    }
    private:
    cudaEvent_t start_, stop_;
};

// This is second version of the gpu implementation
// This version a general benchmarking to compare with CPU,
// Binary operations will be handled single convolution kernel to utilize register memory usage
constexpr std::pair<int, int> register_size(8, 4);
constexpr int nTPB=256;

template <typename T>
struct matrix1d {
	int lenght;
	T *arr;
};

template <typename T>
struct matrix2d {
	int row;
	int col;
	T *arr;
};

template <typename T>
struct matrix3d {
	int row;
	int col;
	int channel;
	T *arr;
};

template <typename T>
struct matrix4d{
	int row;
	int col;
	int channel_in;
	int channel_out;
	T *arr;
};


#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess)
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}


std::pair<int, int> find_binary_size(std::pair<int, int>input_size,  std::pair<int, int>kernel_size){
	int size_x = ceil((input_size.first - register_size.first)
						/static_cast<double>(register_size.first + 1 - kernel_size.first) + 1);
	int size_y = ceil((input_size.second - register_size.second )
						/static_cast<double>(register_size.second + 1 - kernel_size.second) + 1);
	if (size_x < 0)
		size_x = 1;
	if (size_y < 0)
		size_y = 1;
	return std::make_pair(size_x, size_y);
}

size_t choose_block_size(size_t val){
  if (val >= nTPB) return nTPB;
  if (val <= 32) return 32;
  val = (val >> 1) | val;
  val = (val >> 2) | val;
  val = (val >> 4) | val;
  val = (val >> 8) | val;
  val = (val >> 16) | val;
  val++;
  return val;
}

void int2binary(float* input_x, const std::pair<int, int> input_index,
 std::pair<int, int> output_location, unsigned int &output_y, const std::pair<int ,int>register_size, int input_col)
{
	int sign = 0;
	long int pozitive = 1;
	long int negative = 0;
	int count = output_location.second * register_size.second  + output_location.first;

	assert(count < register_size.second * register_size.first);

	for (int j=0; j<register_size.second; j++)
	{
		for(int i=0; i<register_size.first; i++)
		{
			sign = (input_x[(input_index.second) * input_col+ input_index.first + i] > 0) - (input_x[(input_index.second) * input_col+ input_index.first + i] < 0);
			if (sign == 1)
			{
				output_y = pozitive<<count | output_y;
			}
			else if (sign == -1)
			{
				output_y = negative<<count | output_y;
			}
			else
			{
				output_y = negative<<count |output_y;
			}
			if ((input_index.first + i) >=  input_col)
			{
				break;
			}
			count++;
		}
	}

}

void intMat2BinaryMat(float *const& input_mat, unsigned int *const& binary_mat, std::pair<int, int> kernel_size, int input_row, int input_col, int binary_col, int binary_row)
{
	//float * input_mat = input_tensor.arr[i * input_tensor.channel_in + j];
	//unsigned int * binary_mat = binary_tensor.arr[i * input_tensor.channel_in + j];
	int index_x = 0;
	int index_y = 0;
	std::pair<int, int> input_index(0, 0);
	std::pair<int, int> output_location(0, 0);

	// Test
	while(input_row >= input_index.second)
	{
		int i = 0;
		input_index.first = 0;
		index_x = 0;

		while(input_col > i)
		{
			i = input_index.first + register_size.first;
			int2binary(input_mat, input_index, output_location, binary_mat[index_y *binary_col + index_x], register_size, input_col);
			input_index.first = input_index.first + register_size.first + 1 - kernel_size.first;
			index_x++;

		}
		output_location.second++;
		input_index.second++;
		if(input_index.second >= input_row)
			{
				break;
			}
		if (output_location.second % register_size.second == 0)
		{
			output_location.second = 0;
			input_index.second = input_index.second + 1 - kernel_size.second;
			index_y++;
		}
	}
}
std::pair<int, int> BinaryMatMemoryAllocation( std::pair<int, int> input_size, std::pair<int, int> kernel_size)
{
	int size_x = ceil((input_size.first - register_size.first)
						/static_cast<double>(register_size.first + 1 - kernel_size.first) + 1);
	int size_y = ceil((input_size.second - register_size.second )
						/static_cast<double>(register_size.second + 1 - kernel_size.second) + 1);
	if (size_x < 0)
		size_x = 1;
	if (size_y < 0)
		size_y = 1;

	return std::make_pair(size_x, size_y);
}
template <typename T>
__global__ void compK_matrix(T* input_data, T kernel_value,
    T* output_data, int channel_in, int width, int height) {

    float accum;
    int col = threadIdx.x + blockIdx.x * blockDim.x;   //col index
    int row = threadIdx.y + blockIdx.y * blockDim.y;   //row index
    int mask_row_radius = mask_rows / 2;
    int mask_col_radius = mask_cols / 2;


    for (int k = 0; k < channel_in; k++) {      
        if (row < height && col < width) {
            accum = 0;
            int start_row = row - mask_row_radius;  
            int start_col = col - mask_col_radius;  

            for (int i = 0; i < mask_rows; i++) { 

                for (int j = 0; j < mask_cols; j++) { 

                    int row_index = start_row + i; 
                    int col_index = start_col + j; 

                    if (row_index >= 0 && row_index < height && col_index >= 0 && col_index < width) {

                        accum += input_data[(row_index * width + col_index) * channel_in + k] *
                            kernel_value;
                    }
                    else accum += 0;
                }

            }
            output_data[(row * width + col) * channel_in + k] = accum;
        }

    }
}

void __global__ zeroPadding(float* input_tensor, float* output_tensor,  int kernel_row, int kernel_col, int input_col, int input_row, int output_col, int output_row, int output_channel)
{
	int idx = threadIdx.x + blockDim.x * blockIdx.x;
	int op_buffer = idx / output_col; // simple buffer for same operation
	int index_x = (idx % output_col) - (kernel_col - 1)/ 2;
	int index_y = op_buffer%output_row - (kernel_row - 1)/ 2;
	int index_z = op_buffer / output_row;
	if (idx< output_row * output_col * output_channel)
	{
		if(index_x >= 0 && index_y >= 0 )
		{
			if( index_x < input_col && index_y < input_row )
			{
				output_tensor[idx] = input_tensor[(index_z * input_col * input_row ) + ( index_y * input_col ) + index_x];
			}
		}
		else {
			output_tensor[idx] = 0;
		}
	}
}

void __global__ kernel_sum(
		const unsigned int *   d_idata,
		float *  d_odata,
        const int col,
        const int row,
        const int channel_in,
        const int channel_out)
{
	int idx = threadIdx.x+blockDim.x*blockIdx.x;
	if (idx < (col * row * channel_out))
	{

		int tidx = idx%(col*row) + ((idx/(col*row) ) *(col * row * channel_in) ); // indexing for 4 dim , since kernel must sum values with same channel out
		int tsum = 0;
		#pragma unroll
		for (int i = 0; i < channel_in; i++)
		{
			tsum += d_idata[tidx];
			tidx += row * col;
		}
		d_odata[idx] = static_cast<float>(tsum);// / static_cast<float>(channel_in);
	}
}

template<typename T>
__device__ void to_binary_register(
	const T &idata,
	unsigned int &odata,
	 int *output_location)
{
	int sign = (idata > 0) - (idata < 0);
	const unsigned int pozitive = 1;
	const unsigned int negative = 0;
	//int count = output_location[1] * register_size.second  + output_location[0];
	//assert(count < register_size.second * register_size.first);
	if (sign > -1)
	{
		odata = pozitive<<(output_location[1] * register_size.first  + output_location[0]) | odata;
	}
	else
	{
		odata = negative<<(output_location[1] * register_size.first  + output_location[0]) | odata;
	}
}

template<typename T>
void __global__  convert2binary(
	const T *  d_idata,
	unsigned int *  d_odata,
	const int row, const int b_row,
	const int col, const int b_col,
	const int channel,
	const int kernel_row = 3, const int kernel_col = 3)
{
	// Each thread will store a size = 32 array inside their single register
	int idx = threadIdx.x+blockDim.x*blockIdx.x; //register IDX
	// n*(regsiter_size - kernel_size)
	if (idx < (b_row * b_col * channel))
	{

		int input_index[] = {(idx%b_col) * (register_size.first - kernel_col), ((idx/b_col) % b_row)* (register_size.second - kernel_row), (idx/(b_col * b_row) )}; // x, y ,z
		int data_idx = input_index[0] + (input_index[1] * col) + (input_index[2] * row * col);
		//int input_index[] = {data_idx%row, data_idx/col, data_idx/(row*col)}; // from start of array , (x, y, z)
		int register_location[] = {0, 0};
		unsigned int local_register = 0;
		for (int j=0; register_size.second>j; j++)
		{
			for (int i=0; register_size.first>i; i++)
			{
				to_binary_register<T>(d_idata[data_idx], local_register, register_location);
				++data_idx;
				input_index[0] += 1;
				register_location[0] += 1;
				if (input_index[0] == col) break;
			}
			data_idx = data_idx + col - register_location[0];
			input_index[1] += 1;
			input_index[0] = (idx%b_col) * (register_size.first - kernel_col);
			register_location[0] = 0;
			register_location[1] += 1;
			if (input_index[1] == row) break;
		}
		d_odata[idx] = local_register;
	}
}
template<typename T>
void __global__ scalar_multiplication(T* __restrict__ d_idata, const T __restrict__ scalar, const int height, const int width)
{
	int idx = threadIdx.x+blockDim.x*blockIdx.x;
	if (idx<height * width)
	{
		d_idata[idx] = d_idata[idx] * scalar;
	}
}


void __global__ scaling_result(T* __restrict__ d_idata, const T* __restrict__ d_scalar, const int height, const int width, const int channel_out)
{
	int idx = threadIdx.x+blockDim.x*blockIdx.x;
	if (idx<height * width * channel_out)
	{
		d_idata[idx] = d_idata[idx] * d_scalar[idx%(height * width)];
	}
}

void __device__ binary2int(const unsigned int  idata,  unsigned int &odata, int kernel_row, int kernel_col)
{
	constexpr unsigned int mask = 1;
	unsigned int shifter = 0;
	unsigned int buffer = 0;
	for (int j=0; kernel_row>j; ++j)
	{
		for(int i=0; kernel_col>i; ++i)
		{
			buffer += (idata >> shifter) & mask;
			++shifter;
		}
		shifter += register_size.first - kernel_col;
	}
	odata = 2 * buffer - (kernel_row * kernel_col);
}


void __global__ binaryConv2d(
		const unsigned int * input_tensor,
		unsigned int * output_tensor,
		const unsigned int * weight_tensor,
		int input_row, int input_col,
		int kernel_row, int kernel_col,
		int output_row, int output_col,
		int channel_in, int channel_out
		)
{

	int idx = threadIdx.x +blockDim.x*blockIdx.x;
	int conv_per_row = register_size.second - (kernel_row - 1);
	int conv_per_column = register_size.first - (kernel_col - 1);
	int output_index_x = (idx % input_col) * conv_per_column;
	int output_index_y = ((idx / input_col) % input_row) * conv_per_row;

	if (idx < input_row * input_col * channel_in * channel_out)
	{
		unsigned int register_buffer = input_tensor[idx % (input_row * input_col * channel_in)];
		if ( (output_index_x + conv_per_column) > output_col)
		{
			conv_per_column = output_col - output_index_x;
		}
		if ( (output_index_y + conv_per_row) > output_row)
		{
			conv_per_row = output_row - output_index_y;
		}

		unsigned int mask = std::pow(2, kernel_col) - 1;
		for (int j=1; kernel_row > j; j++)
		{
			mask = (mask<<register_size.first) | static_cast<unsigned int>(std::pow(2, kernel_col) - 1);
		}
		int default_index = (idx / (input_row * input_col) ) *  (output_col * output_row);
		auto weight_index = idx / (input_row * input_col);
		unsigned int shifter = 0;
		for (int j=0; conv_per_row>j; ++j)
		{
			for (int i=0; conv_per_column>i; ++i)
			{
				unsigned int buffer = (~(register_buffer>>shifter) ^ (weight_tensor[weight_index]) ) & mask;
				binary2int(buffer, output_tensor[default_index + (output_index_y+j)*output_col + output_index_x + i], kernel_row, kernel_col);
				++shifter;
			}
			// Check if register is not fully filled,
			// if not add shifter the missing shift amount
			shifter += register_size.second - conv_per_column;
		}
	}

}





// This part must be updated to concurrent execution
void xnor_convolution(matrix3d<float> &h_input_tensor, matrix4d<unsigned int> &h_weight_tensor, matrix3d<float> &h_output_tensor, const float alpha, int kernel_row, int kernel_col, bool padding=true)
{

	cudaEvent_t start, stop;
	cudaEvent_t start1, stop1;
	cudaEvent_t start2, stop2;
	cudaEventCreate(&start2);
	cudaEventCreate(&stop2);
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
	cudaEventCreate(&start1);
	cudaEventCreate(&stop1);


	matrix3d<float> d_input_tensor;
	d_input_tensor.col = h_input_tensor.col;
	d_input_tensor.row = h_input_tensor.row;
	d_input_tensor.channel = h_input_tensor.channel;
	auto copy_size = sizeof(float) * d_input_tensor.col* d_input_tensor.row * d_input_tensor.channel;
	cudaMalloc((void **)&d_input_tensor.arr, copy_size);
	cudaMemcpy(d_input_tensor.arr, h_input_tensor.arr, copy_size, cudaMemcpyHostToDevice);
	//
	// Calculate K matrix
	// Use async steam2
	cudaStream_t stream1;
	cudaStreamCreate(&stream1);
	matrix2d<float> d_K_matrix;
	d_K_matrix.col = h_input_tensor.col;
	d_K_matrix.row = h_input_tensor.row;
	copy_size = sizeof(float) * d_K_matrix.col* d_K_matrix.row;
	cudaMalloc((void **)&d_K_matrix.arr, copy_size);
	const float kernel_value = 1.0 / static_cast<float>(h_weight_tensor.row * h_weight_tensor.col);
	auto block_size = choose_block_size(h_input_tensor.row * h_input_tensor.col);
	auto grid_size = (h_input_tensor.row * h_input_tensor.col+ block_size - 1)/block_size; 
	compK_matrix<float><<<grid_size, block_size, stream1>>>(d_input_tensor.arr, kernel_value,
		d_K_matrix.arr, d_input_tensor.channel, d_input_tensor.width, d_input_tensor.height);
	//
	scalar_multiplication<float><<<grid_size, block_size, stream1>>>(d_K_matrix.arr, alpha, height, width);
	matrix3d<float> d_padded_input_tensor;
	d_padded_input_tensor.row = h_input_tensor.row + kernel_row - 1;
	d_padded_input_tensor.col = h_input_tensor.col + kernel_col - 1;
	d_padded_input_tensor.channel = h_input_tensor.channel;
	copy_size = sizeof(float) * d_padded_input_tensor.row * d_padded_input_tensor.col * d_padded_input_tensor.channel;
	gpuErrchk(cudaMalloc((void **)&d_padded_input_tensor.arr, copy_size));

	block_size = choose_block_size(d_padded_input_tensor.row * d_padded_input_tensor.col * d_padded_input_tensor.channel);
	grid_size = (d_padded_input_tensor.row * d_padded_input_tensor.col * d_padded_input_tensor.channel + block_size - 1)/block_size;
	zeroPadding<<<grid_size, block_size>>>(d_input_tensor.arr, d_padded_input_tensor.arr,  kernel_row, kernel_col, d_input_tensor.col, d_input_tensor.row, d_padded_input_tensor.row, d_padded_input_tensor.col, d_padded_input_tensor.channel);
	//cudaFree(d_input_tensor.arr);
	auto binary_size = find_binary_size(std::make_pair(h_input_tensor.col, h_input_tensor.row), std::make_pair(kernel_col, kernel_row));

	matrix3d<unsigned int> d_binary_input_tensor;
	d_binary_input_tensor.row = binary_size.second;
	d_binary_input_tensor.col = binary_size.first;
	d_binary_input_tensor.channel = d_padded_input_tensor.channel;
	copy_size = sizeof(unsigned int) * d_binary_input_tensor.row * d_binary_input_tensor.col * d_binary_input_tensor.channel;

	gpuErrchk(cudaMalloc((void **)&d_binary_input_tensor.arr, copy_size));
	cudaEventRecord(start, 0);
	convert2binary<<<grid_size, block_size>>>(d_padded_input_tensor.arr, d_binary_input_tensor.arr,
			d_padded_input_tensor.row, d_binary_input_tensor.row,
			d_padded_input_tensor.col, d_binary_input_tensor.col,
			d_binary_input_tensor.channel,
			kernel_row, kernel_col);
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	float milliseconds = 0;
	cudaEventElapsedTime(&milliseconds, start, stop);
	std::cout<<"Int2Binary Time= "<< milliseconds<<std::endl;
	//cudaFree(d_padded_input_tensor.arr);
	matrix4d<unsigned int> d_convolution_buffer;
	d_convolution_buffer.col = h_input_tensor.col;
	d_convolution_buffer.row = h_input_tensor.row;
	d_convolution_buffer.channel_in = h_input_tensor.channel;
	d_convolution_buffer.channel_out = h_weight_tensor.channel_out;
	copy_size = sizeof(unsigned int) * d_convolution_buffer.col * d_convolution_buffer.row * d_convolution_buffer.channel_in * d_convolution_buffer.channel_out;
	gpuErrchk(cudaMalloc((void **)& d_convolution_buffer.arr, copy_size));
	matrix4d<unsigned int> d_weight_tensor;
	d_weight_tensor.row = h_weight_tensor.row;
	d_weight_tensor.col = h_weight_tensor.col;
	d_weight_tensor.channel_in = h_weight_tensor.channel_in;
	d_weight_tensor.channel_out = h_weight_tensor.channel_out;
	copy_size = sizeof(unsigned int) * d_weight_tensor.row *d_weight_tensor.col * d_weight_tensor.channel_in * d_weight_tensor.channel_out;
	gpuErrchk(cudaMalloc((void**)&d_weight_tensor.arr, copy_size)); // pinned memory can be tested
	cudaMemcpy(d_weight_tensor.arr, h_weight_tensor.arr, copy_size, cudaMemcpyHostToDevice);
	block_size = choose_block_size(d_convolution_buffer.col * d_convolution_buffer.row * d_convolution_buffer.channel_in * d_convolution_buffer.channel_out);
	grid_size = (d_convolution_buffer.col* d_convolution_buffer.row * d_convolution_buffer.channel_in * d_convolution_buffer.channel_out + block_size - 1)/ block_size;
	cudaEventRecord(start1, 0);
	binaryConv2d<<<grid_size, block_size>>>(d_binary_input_tensor.arr, d_convolution_buffer.arr, d_weight_tensor.arr
			,d_binary_input_tensor.row, d_binary_input_tensor.col
			, kernel_row, kernel_col
			,d_convolution_buffer.row, d_convolution_buffer.col
			,d_convolution_buffer.channel_in, d_convolution_buffer.channel_out
			);
	cudaEventRecord(stop1, 0);
	cudaEventSynchronize(stop1);
	cudaEventElapsedTime(&milliseconds, start1, stop1);
	std::cout<<"Convolution Time= "<< milliseconds<<std::endl;
	cudaFree(d_binary_input_tensor.arr);
	matrix3d<float> d_output_tensor;
	d_output_tensor.col = h_output_tensor.col;
	d_output_tensor.row = h_output_tensor.row;
	d_output_tensor.channel = h_output_tensor.channel;
	copy_size = sizeof(float) * d_output_tensor.row * d_output_tensor.col * d_output_tensor.channel;
	cudaMalloc((void**)&d_output_tensor.arr, copy_size);
	block_size = choose_block_size(d_output_tensor.row * d_output_tensor.col * d_output_tensor.channel);
	grid_size = (d_output_tensor.row * d_output_tensor.col * d_output_tensor.channel + block_size - 1) / block_size;
	cudaEventRecord(start2, 0);
	kernel_sum<<<grid_size, block_size>>>(d_convolution_buffer.arr, d_output_tensor.arr, d_output_tensor.col, d_output_tensor.row, d_convolution_buffer.channel_in, d_convolution_buffer.channel_out);
	cudaEventRecord(stop2, 0);
	cudaEventSynchronize(stop2);
	cudaEventElapsedTime(&milliseconds, start2, stop2);
	std::cout<<"Summation Time= "<< milliseconds<<std::endl;
	cudaDeviceSynchronize()
	cudaStreamDestroy(stream1);
	// Multiplication with K and alpha
	//scaling_result<<<>>>();
	//cudaFree(d_convolution_buffer.arr);
	cudaMemcpy(h_output_tensor.arr, d_output_tensor.arr, copy_size, cudaMemcpyDeviceToHost);
	//cudaFree(d_output_tensor.arr);
	cudaEventDestroy(start);
	cudaEventDestroy(stop);
	cudaEventDestroy(start1);
	cudaEventDestroy(stop1);
	cudaEventDestroy(start2);
	cudaEventDestroy(stop2);

	return;

}



int main()
{
	int row = 512;
	int col = 512;
	int kernel_row = 3;
	int kernel_col = 3;

	int channel_in = 1;
	int channel_out = 1;
	matrix3d<float> input_tensor;
	matrix4d<float> weight_tensor;
	input_tensor.row = row;
	input_tensor.col = col;
	input_tensor.channel = channel_in;
	// Init Matrices
	input_tensor.arr = new float [input_tensor.channel * input_tensor.row * input_tensor.col];
	weight_tensor.row = kernel_row;
	weight_tensor.col = kernel_col;
	weight_tensor.channel_in = channel_in;
	weight_tensor.channel_out = channel_out;
	weight_tensor.arr = new float [weight_tensor.channel_in * weight_tensor.channel_out * weight_tensor.row * weight_tensor.col];

	bool padding = true;
	// Default Values
	for(int i=0; input_tensor.channel > i; ++i)
	{
		for (int j=0; input_tensor.col * input_tensor.row> j; ++j)
		{
			input_tensor.arr[i * input_tensor.col * input_tensor.row + j] = (rand() % 50) - 25;
		}
	}
	for(int i=0; weight_tensor.channel_in * weight_tensor.channel_out > i; ++i)
	{
		for (int j=0; weight_tensor.col * weight_tensor.row> j; ++j)
		{
			weight_tensor.arr[i * weight_tensor.col * weight_tensor.row + j] = (rand() % 50) -25;
		}
	}
	// Make Weights binary as preProcessing
	auto weight_size = BinaryMatMemoryAllocation(std::make_pair(weight_tensor.row, weight_tensor.col), std::make_pair(weight_tensor.col, weight_tensor.row));
	matrix4d<unsigned int> binary_weight_tensor;
	binary_weight_tensor.col = weight_size.first;
	binary_weight_tensor.row = weight_size.second;
	binary_weight_tensor.channel_in = weight_tensor.channel_in;
	binary_weight_tensor.channel_out = weight_tensor.channel_out;
	binary_weight_tensor.arr = new unsigned int [binary_weight_tensor.channel_in * binary_weight_tensor.channel_out *binary_weight_tensor.row * binary_weight_tensor.col];
	for (int i= 0; weight_tensor.channel_out > i; ++i)
	{
		for(int j=0; weight_tensor.channel_in > j; ++j)
		{
			intMat2BinaryMat(&weight_tensor.arr[(i * weight_tensor.channel_in + j) * weight_tensor.row * weight_tensor.col], &binary_weight_tensor.arr[i * weight_tensor.channel_in + j],
					std::make_pair(weight_tensor.col, weight_tensor.row), weight_tensor.row, weight_tensor.col, binary_weight_tensor.col, binary_weight_tensor.row);
		}
	}
	delete weight_tensor.arr;
	// A sample layer
	matrix3d<float> output_tensor;
	output_tensor.col = input_tensor.col;
	output_tensor.row = input_tensor.row;
	output_tensor.channel = input_tensor.channel;
	output_tensor.arr = new float [input_tensor.col* input_tensor.row * input_tensor.channel];
	xnor_convolution(input_tensor, binary_weight_tensor, output_tensor, weight_tensor.row, weight_tensor.col ,padding);

	delete[] input_tensor.arr;
	delete[] binary_weight_tensor.arr;
	delete[] output_tensor.arr;
	return 0;
}



