// A real GPU TensorRT 10 inference acceptance test: y = x + x.
// This must build an engine and run enqueueV3; loading libnvinfer alone
// does not prove that TensorRT can execute work on the Jetson GPU.
#include <NvInfer.h>
#include <cuda_runtime_api.h>
#include <cmath>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

class Logger final : public nvinfer1::ILogger {
 public:
  void log(Severity severity, char const* message) noexcept override {
    if (severity <= Severity::kERROR) std::cerr << "[TensorRT] " << message << '\n';
  }
};

void require(bool good, const char* what) {
  if (!good) throw std::runtime_error(what);
}
void cuda_check(cudaError_t code, const char* what) {
  if (code != cudaSuccess) {
    throw std::runtime_error(std::string(what) + ": " + cudaGetErrorString(code));
  }
}

int main() {
  try {
    Logger logger;
    auto builder = std::unique_ptr<nvinfer1::IBuilder>(
        nvinfer1::createInferBuilder(logger));
    require(bool(builder), "createInferBuilder failed");
    auto network = std::unique_ptr<nvinfer1::INetworkDefinition>(
        builder->createNetworkV2(0U));
    require(bool(network), "createNetworkV2 failed");
    auto* input = network->addInput(
        "x", nvinfer1::DataType::kFLOAT, nvinfer1::Dims4{1, 1, 1, 1});
    require(input, "addInput failed");
    auto* add = network->addElementWise(
        *input, *input, nvinfer1::ElementWiseOperation::kSUM);
    require(add, "addElementWise failed");
    auto* output = add->getOutput(0);
    require(output, "addElementWise output failed");
    output->setName("y");
    network->markOutput(*output);

    auto config = std::unique_ptr<nvinfer1::IBuilderConfig>(
        builder->createBuilderConfig());
    require(bool(config), "createBuilderConfig failed");
    auto plan = std::unique_ptr<nvinfer1::IHostMemory>(
        builder->buildSerializedNetwork(*network, *config));
    require(bool(plan), "buildSerializedNetwork failed");

    auto runtime = std::unique_ptr<nvinfer1::IRuntime>(
        nvinfer1::createInferRuntime(logger));
    require(bool(runtime), "createInferRuntime failed");
    auto engine = std::unique_ptr<nvinfer1::ICudaEngine>(
        runtime->deserializeCudaEngine(plan->data(), plan->size()));
    require(bool(engine), "deserializeCudaEngine failed");
    auto context = std::unique_ptr<nvinfer1::IExecutionContext>(
        engine->createExecutionContext());
    require(bool(context), "createExecutionContext failed");

    float host_input = 3.25f, host_output = 0.0f;
    float *gpu_input = nullptr, *gpu_output = nullptr;
    cudaStream_t stream = nullptr;
    cuda_check(cudaStreamCreate(&stream), "cudaStreamCreate");
    cuda_check(cudaMalloc(reinterpret_cast<void**>(&gpu_input), sizeof(float)),
               "cudaMalloc input");
    cuda_check(cudaMalloc(reinterpret_cast<void**>(&gpu_output), sizeof(float)),
               "cudaMalloc output");
    cuda_check(cudaMemcpyAsync(gpu_input, &host_input, sizeof(float),
                              cudaMemcpyHostToDevice, stream), "input copy");
    require(context->setTensorAddress("x", gpu_input), "setTensorAddress x");
    require(context->setTensorAddress("y", gpu_output), "setTensorAddress y");
    require(context->enqueueV3(stream), "TensorRT enqueueV3 failed");
    cuda_check(cudaMemcpyAsync(&host_output, gpu_output, sizeof(float),
                              cudaMemcpyDeviceToHost, stream), "output copy");
    cuda_check(cudaStreamSynchronize(stream), "CUDA stream synchronisation");
    require(std::fabs(host_output - 6.5f) < 0.0001f,
            "TensorRT GPU output did not match expected 6.5");
    cuda_check(cudaFree(gpu_output), "cudaFree output");
    cuda_check(cudaFree(gpu_input), "cudaFree input");
    cuda_check(cudaStreamDestroy(stream), "cudaStreamDestroy");
    std::cout << "PASS: TensorRT 10 engine built and GPU inference returned "
              << host_output << '\n';
    return 0;
  } catch (std::exception const& e) {
    std::cerr << "FAIL: TensorRT GPU inference: " << e.what() << '\n';
    return 1;
  }
}
