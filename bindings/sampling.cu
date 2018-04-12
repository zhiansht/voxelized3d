//
// Created by russoul on 12.04.18.
//

#include "helper_math.h"
#include "cuda_noise.cuh"
#include <device_launch_parameters.h>
#include <cstdlib>
#include <iostream>
#include <zconf.h>


struct vec3f{
    float array[3];
};


__host__ __device__ __forceinline__ vec3f make_vec3f(float x, float y, float z){
    vec3f ret;
    ret.array[0] = x;
    ret.array[1] = y;
    ret.array[2] = z;

    return ret;
}

__host__ __device__ __forceinline__ vec3f operator+(vec3f a, vec3f b){
    vec3f ret;

    ret.array[0] = a.array[0] + b.array[0];
    ret.array[1] = a.array[1] + b.array[1];
    ret.array[2] = a.array[2] + b.array[2];

    return ret;
}

__host__ __device__ __forceinline__ vec3f operator-(vec3f a, vec3f b){
    vec3f ret;

    ret.array[0] = a.array[0] - b.array[0];
    ret.array[1] = a.array[1] - b.array[1];
    ret.array[2] = a.array[2] - b.array[2];

    return ret;
}


__host__ __device__ __forceinline__ vec3f operator*(vec3f a, float k){
    vec3f ret;

    ret.array[0] = a.array[0] * k;
    ret.array[1] = a.array[1] * k;
    ret.array[2] = a.array[2] * k;

    return ret;
}

__host__ __device__ __forceinline__ vec3f operator/(vec3f a, float k){
    vec3f ret;

    ret.array[0] = a.array[0] / k;
    ret.array[1] = a.array[1] / k;
    ret.array[2] = a.array[2] / k;

    return ret;
}

__host__ __device__ __forceinline__ float dot(vec3f a, vec3f b){
    return a.array[0] * b.array[0] + a.array[1] * b.array[1] + a.array[2] * b.array[2];
}

__host__ __device__ __forceinline__ float norm(vec3f a){
    return sqrtf(dot(a,a));
}

__host__ __device__ __forceinline__ vec3f normalize(vec3f a){
    return a / norm(a);
}

__host__ __device__ __forceinline__ vec3f fromFloat3(float3 a){
    return make_vec3f(a.x, a.y, a.z);
}

__host__ __device__ __forceinline__ float3 toFloat3(vec3f a){
    return make_float3(a.array[0], a.array[1], a.array[2]);
}

struct Line3{
    float3 start;
    float3 end;
};

//=============== uniform voxel storage ==================
struct HermiteData{
    float3 intersection;
    float3 normal;
};

struct UniformVoxelStorage{
    uint cellCount;
    float* grid;
    HermiteData** edgeInfo;
};
//========================================================


__constant__ int specialTable1[256][3];

__constant__ uint specialTable2[12];

__constant__ float3 cornerPoints[8];

__constant__ uint2 edgePairs[12];


inline __device__ __host__ uint indexDensity(uint cellCount, uint x, uint y, uint z){
    return z * (cellCount + 2) * (cellCount + 2) + y * (cellCount + 2) + x;
}

inline __device__ __host__ uint indexCell(uint cellCount, uint x, uint y, uint z){
    return z * (cellCount + 1) * (cellCount + 1) + y * (cellCount + 1) + x;
}


inline __device__ void loadDensity(uint x, uint y, uint z, float3 offset, float a, UniformVoxelStorage storage, int seed){
    auto p = offset + make_float3(x * a, y * a, z * a);
    auto den = cudaNoise::perlinNoise(p, 1, seed);
    //printf("%f for px=%f py=%f pz=%f x=%u y=%u z=%u i=%u a=%f size=%u\n", den, p.x, p.y, p.z, x,y,z, indexDensity(storage.cellCount, x,y,z),a,storage.cellCount);


    storage.grid[indexDensity(storage.cellCount, x,y,z)] = den;

    //printf("%f for px=%f py=%f pz=%f x=%u y=%u z=%u i=%u a=%f size=%u\n", storage.grid[indexDensity(storage.cellCount, x,y,z)], p.x, p.y, p.z, x,y,z, indexDensity(storage.cellCount, x,y,z),a,storage.cellCount);
}

__global__ void kernelLoadDensity(float3 offset, float a, UniformVoxelStorage storage, int seed){
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    //printf("kernel bx=%d, tx=%d\n", blockIdx.x, threadIdx.x);

    uint x = i % (storage.cellCount + 2);
    uint y = (i / (storage.cellCount + 2)) % (storage.cellCount + 2);
    uint z = (i / (storage.cellCount + 2) / (storage.cellCount + 2)) % (storage.cellCount + 2);

    loadDensity(x,y,z, offset, a, storage, seed);
}

__device__ float3 sampleSurfaceIntersection(Line3 line, uint n, int seed){
    auto ext = line.end - line.start;

    auto norm = length(ext);
    auto dir = ext / norm;

    auto center = line.start + ext * 0.5F;
    auto curExt = norm * 0.25F;

    for (int i = 0; i < n; ++i) {
        auto point1 = center - dir * curExt;
        auto point2 = center + dir * curExt;
        auto den1 = fabsf(cudaNoise::perlinNoise(point1, 1, seed));
        auto den2 = fabsf(cudaNoise::perlinNoise(point2, 1, seed));

        if(den1 <= den2){
            center = point1;
        }else{
            center = point2;
        }
    }

    return center;
}

__device__ float3 calculateNormal(float3 point, float eps, int seed){
    float d = cudaNoise::perlinNoise(point, 1, seed);
    return normalize(make_float3(cudaNoise::perlinNoise(make_float3(point.x + eps, point.y, point.z), 1, seed) - d,
                       cudaNoise::perlinNoise(make_float3(point.x, point.y + eps, point.z), 1, seed) - d,
                       cudaNoise::perlinNoise(make_float3(point.x, point.y, point.z + eps), 1, seed) - d
    ));
}


__global__ void loadCell(float3 offset, float a, uint acc, UniformVoxelStorage storage, int seed){
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    uint x = i % (storage.cellCount + 1);
    uint y = (i / (storage.cellCount + 1)) % (storage.cellCount + 1);
    uint z = (i / (storage.cellCount + 1) / (storage.cellCount + 1)) % (storage.cellCount + 1);

    auto cellMin = offset + make_float3(x * a, y * a, z * a);

    uint config = 0;

    if(storage.grid[indexDensity(storage.cellCount, x,y,z)] < 0.0){
        config |= 1;
    }
    if(storage.grid[indexDensity(storage.cellCount, x+1,y,z)] < 0.0){
        config |= 2;
    }
    if(storage.grid[indexDensity(storage.cellCount, x+1,y,z+1)] < 0.0){
        config |= 4;
    }
    if(storage.grid[indexDensity(storage.cellCount, x,y,z+1)] < 0.0){
        config |= 8;
    }

    if(storage.grid[indexDensity(storage.cellCount, x,y+1,z)] < 0.0){
        config |= 16;
    }
    if(storage.grid[indexDensity(storage.cellCount, x+1,y+1,z)] < 0.0){
        config |= 32;
    }
    if(storage.grid[indexDensity(storage.cellCount, x+1,y+1,z+1)] < 0.0){
        config |= 64;
    }
    if(storage.grid[indexDensity(storage.cellCount, x,y+1,z+1)] < 0.0){
        config |= 128;
    }

    int* entry = specialTable1[config];

    if(*entry != -2){
        int curEntry = entry[0];
        HermiteData* edges = (HermiteData*)malloc(sizeof(HermiteData) * 3); //allocated dynamically on device

        while(curEntry != -2){
            auto corners = edgePairs[curEntry];
            Line3 edge = {cellMin + cornerPoints[corners.x] * a, cellMin + cornerPoints[corners.y] * a};
            auto intersection = sampleSurfaceIntersection(edge, (uint)(log2f(acc) + 1), seed);
            auto normal = calculateNormal(intersection, a / 1024.0F, seed);




            edges[specialTable2[curEntry]] = {intersection, normal};

            curEntry = *(++entry);
        }

        storage.edgeInfo[indexCell(storage.cellCount, x,y,z)] = edges;
    }
}

extern "C" void testVec3f(float3 a){
    printf("x=%f, y=%f, z=%f\n", a.x, a.y, a.z);
    printf("sizeof float3 = %d\n", sizeof(float3));

}

extern "C" void sampleGPU(float3 offset, float a, uint acc, UniformVoxelStorage* storage){
    auto size = storage->cellCount;

    printf("info: ox=%f oy=%f oz=%f a=%f\n size=%d", offset.x, offset.y, offset.z, a, size);


    std::cout << "start" << std::endl;
    std::flush(std::cout);

    int seed = 343842934;

    float* grid_d;
    HermiteData** edgeInfo_d;

    cudaMalloc(&grid_d, sizeof(float) * (size + 2) * (size + 2) * (size + 2));
    cudaMalloc(&edgeInfo_d, sizeof(HermiteData*) * (size + 1)*(size + 1)*(size + 1));

    UniformVoxelStorage storage_d = {size, grid_d, edgeInfo_d};


    std::cout << "before density" << std::endl;

    kernelLoadDensity<<<(size+2)*(size+2),(size+2)>>>(offset, a, storage_d, seed);



    std::cout << "after density" << std::endl;

    std::flush(std::cout);

    int specialTable1_local[256][3] = {


            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {-2, -2, -2},
            {0, 3, 8},
            {0, -2, -2},
            {3, 8, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {3, -2, -2},
            {0, 8, -2},
            {0, 3, -2},
            {8, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {8, -2, -2},
            {0, 3, -2},
            {0, 8, -2},
            {3, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},
            {3, 8, -2},
            {0, -2, -2},
            {0, 3, 8},
            {-2, -2, -2},

    };


    float3 cornerPoints_local[8] = {
            make_float3(0.0f, 0.0f, 0.0f),
            make_float3(1.0f, 0.0f, 0.0f), //clockwise starting from zero y min
            make_float3(1.0f, 0.0f, 1.0f),
            make_float3(0.0f, 0.0f, 1.0f),


            make_float3(0.0f, 1.0f, 0.0f),
            make_float3(1.0f, 1.0f, 0.0f), //y max
            make_float3(1.0f, 1.0f, 1.0f),
            make_float3(0.0f, 1.0f, 1.0f)
    };

    uint2 edgePairs_local[12] = {
       make_uint2(0,1),
       make_uint2(1,2),
       make_uint2(3,2),
       make_uint2(0,3),

       make_uint2(4,5),
       make_uint2(5,6),
       make_uint2(7,6),
       make_uint2(4,7),

       make_uint2(4,0),
       make_uint2(1,5),
       make_uint2(2,6),
       make_uint2(3,7)
    };

    /*for (int i = 0; i < 256; ++i) {
        cudaMemcpyToSymbol(specialTable1, specialTable1_local[i], sizeof(int) * 3, sizeof(int) * 3 * i);
    }


    uint specialTable2_local[12] = {0,1,0,1,0,1,0,1,2,2,2,2};

    cudaMemcpyToSymbol(specialTable2, specialTable2_local, sizeof(uint) * 12);


    cudaMemcpyToSymbol(cornerPoints, cornerPoints_local, sizeof(float3) * 8);
    cudaMemcpyToSymbol(edgePairs, edgePairs_local, sizeof(uint2) * 12);

    std::cout << "before load" << std::endl;
    std::flush(std::cout);

    loadCell<<<(size+1)*(size+1),(size+1)>>>(offset, a, acc, storage_d, seed);

    cudaEvent_t kernelExec;
    cudaEventCreate(&kernelExec);

    const int timeout = 20000000;
    int progressed = 0;
    while (cudaEventQuery(kernelExec) != cudaSuccess) {
        usleep(20000);
        progressed += 20000;
        if (progressed >= timeout) {
            cudaDeviceReset();

            throw std::runtime_error("timeout");
        }
    }

    std::cout << "after load" << std::endl;
    std::flush(std::cout);

    cudaDeviceSynchronize();*/



    cudaMemcpy(storage->grid, storage_d.grid, sizeof(float) * (size + 2) * (size + 2) * (size + 2), cudaMemcpyDeviceToHost);

    std::cout << "after grid copy" << std::endl;

    std::flush(std::cout);

   /* for (int k = 0; k < (size + 2) * (size + 2) * (size + 2); ++k) {
        if(storage->grid[k] != 0.0F)
            printf("sampled: %f\n",storage->grid[k]);
    }

    cudaFree(grid_d);


    cudaMemcpy(storage->edgeInfo, storage_d.edgeInfo, sizeof(HermiteData*) * (size + 1) * (size + 1) * (size + 1), cudaMemcpyDeviceToHost);

    for (int j = 0; j < (size + 1)*(size + 1)*(size + 1); ++j) {
        auto* ptr_d = storage->edgeInfo[j];


        using namespace std;
        if(ptr_d){
            HermiteData* data = static_cast<HermiteData *>(malloc(sizeof(HermiteData) * 3));
            cudaMemcpy(data, ptr_d, sizeof(HermiteData) * 3, cudaMemcpyDeviceToHost);
            cudaFree(ptr_d);

            storage->edgeInfo[j] = data;
        }
    }

    cudaFree(edgeInfo_d);*/


}


