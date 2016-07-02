#pragma once

#include <cmath>
#include <cublas_v2.h>   
#include <thrust/device_vector.h>
#include <thrust/functional.h>

#include "simd_math_prims.h"

namespace thrust
{
  namespace detail
  {
    namespace functional
    {
    
      template<typename T>
      struct unary_exp : public thrust::unary_function<T,T> {
        __host__ __device__
        T operator()(const T &x) const { return expapprox(x); }
      };
      
      template<typename Eval>
      __host__ __device__
      actor<composite<unary_operator<unary_exp>, actor<Eval>>>
      Exp(const actor<Eval> &_1) {
        return compose(unary_operator<unary_exp>(), _1);
      }
      
      template<typename T>
      struct unary_log : public thrust::unary_function<T,T> {
        __host__ __device__
        T operator()(const T &x) const { return logapprox(x); }
      };
      
      template<typename Eval>
      __host__ __device__
      actor<composite<unary_operator<unary_log>, actor<Eval>>>
      Log(const actor<Eval> &_1) {
        return compose(unary_operator<unary_log>(), _1);
      } 
      
      template<typename T>
      struct unary_logit : public thrust::unary_function<T,T> {
        __host__ __device__
        T operator()(const T &x) const { return 1.0 / (1.0 + expapprox(-x)); }
      };
      
      template<typename Eval>
      __host__ __device__
      actor<composite<unary_operator<unary_logit>, actor<Eval>>>
      Logit(const actor<Eval> &_1) {
        return compose(unary_operator<unary_logit>(), _1);
      }
      
      template<typename T>
      struct unary_tanh : public thrust::unary_function<T,T> {
        __host__ __device__
        T operator()(const T &x) const { return tanhapprox(x); }
      };
      
      template<typename Eval>
      __host__ __device__
      actor<composite<unary_operator<unary_tanh>, actor<Eval>>>
      Tanh(const actor<Eval> &_1) {
        return compose(unary_operator<unary_tanh>(), _1);
      }
      
      template<typename T1, typename T2>
      __host__ __device__
      actor<composite<binary_operator<thrust::maximum>, actor<T1>, actor<T2>>>
      Max(const actor<T1> &_1, const actor<T2> &_2) {
        return compose(binary_operator<thrust::maximum>(),
                       make_actor(_1),
                       make_actor(_2));
      }
    }
  }
}