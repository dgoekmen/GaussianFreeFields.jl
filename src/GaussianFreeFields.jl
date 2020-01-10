__precompile__(true)

module GaussianFreeFields

import Contour,
       Interpolations,
       FFTW,
       SparseArrays,
       LinearAlgebra

export DGFF,
       fix_boundary_values,
       harmonicextension,
       inside, 
       flowline,
       interpolate 

function DGFF(n::Int)
    h = complex(zeros(n,n))
    for j=1:n
        for k=1:n
            h[j,k] = 1/sqrt(2.0)*(j+k == 2 ? 0 : (randn() + im*randn()) * 1/sqrt(sin((j-1)*pi/n)^2+ sin((k-1)*pi/n)^2))
        end
    end
    return real(n*1/sqrt(2)*FFTW.ifft(h))
end

function DGFF(m::Int,n::Int)
    h = complex(zeros(m,n))
    for j=1:m
        for k=1:n
            h[j,k] = 1/sqrt(2.0)*(j+k == 2 ? 0 :
                                  randn() + im*randn() *
                                  1/sqrt(sin((j-1)*pi/m)^2+(sin((k-1)*pi/n))^2))
        end
    end
    return real(n/sqrt(2)*FFTW.ifft(h))
end

"Return the array obtained by subtracting from `h` the 
harmonic extension of the values around the edge of 
the array `boundary_values`"
function fix_boundary_values(h::Array{Float64,2},
                             boundary_values::Array{Float64,2}=zeros(h))
    m,n = size(h)
    #sparse matrix with ones in top left, lower right positions
    cornersonly(m) = SparseArrays.sparse([1,m],[1,m],[1.0,1.0])
    #sparse matrix with ones along diagonal except top-left, lower-right
    eyenocorners(n) = SparseArrays.sparse(LinearAlgebra.I,n,n) - cornersonly(n)
    A = cornersonly(m)
    B = SparseArrays.sparse(LinearAlgebra.I,n,n)
    D_dense = zeros(n,n); 
    for i=1:n-1 
        D_dense[i,i+1] = -1; 
        D_dense[i+1,i] = -1; 
        D_dense[i,i] = 4; 
    end
    D_dense[1,1] = 1
    D_dense[1,2] = 0 
    D_dense[n,n-1] = 0
    D_dense[n,n] = 1
    D = SparseArrays.sparse(D_dense);
    E_dense = zeros(m,m)
    for i=1:m-1 
        E_dense[i,i+1]=-1
        E_dense[i+1,i]=-1 
    end
    E_dense[m,m-1] = 0
    E_dense[1,2] = 0
    E = SparseArrays.sparse(E_dense)
    Δ = kron(A,B) + kron(eyenocorners(m),D) + kron(E,eyenocorners(n))
    boundary = zeros(m*n)
    for i in 1:m-1
        boundary[n*i+1] = h[i+1,1] - boundary_values[i+1,1]
        boundary[n*i] = h[i,n] - boundary_values[i,n]
    end
    for i in 1:n-1
        boundary[i] = h[1,i] - boundary_values[1,i]
        boundary[end-n+i] = h[m,i] - boundary_values[m,i]
    end
    boundary[end] = h[m,n]
    
    return h - transpose(reshape(Array(LinearAlgebra.lu(Δ) \ boundary),n,m))
end

function harmonicextension(h::Array{T,2},vertices::Set) where T<:Number
    m,n = size(h)
    function neighbors(i::Int,j::Int)
        return [(i-1,j),(i+1,j),(i,j-1),(i,j+1)]
    end
    vertexmap = Dict(map(reverse,enumerate([(i,j) for i=1:m,j=1:n][:])));
    I = Int64[]
    J = Int64[]
    V = Float64[]
    b = zeros(m*n)
    for v in keys(vertexmap)
        if v in vertices
            k = vertexmap[v]
            push!(I,k); push!(J,k); push!(V,1)
            b[k] = h[k]
        else
            k = vertexmap[v]
            for nb in neighbors(v...)
                try
                    j = vertexmap[nb]
                    push!(I,k); push!(J,j); push!(V,1)
                    push!(I,k); push!(J,k); push!(V,-1)
                catch
                end
            end
        end
    end
    A = SparseArrays.sparse(I,J,V)
    return reshape(LinearAlgebra.lu(A) \ b,m,n)
end

# `inside` determines whether a point p is inside a curve γ
# by checking the number of points of intersection between γ
# and a ray emanating from p 
function inside(p::Array{Float64,1},γ::Array{Float64,2})
    if γ[1,:] != γ[length(γ[:,1]),:] 
        return false
    end
    cntr = 0; m = sqrt(2); # the slope is an arbitrary irrational number
    for i=1:length(γ[:,1])-1
        (x1,y1,x2,y2) = (γ[i,1],γ[i,2],γ[i+1,1],γ[i+1,2])
        if ((y2 - p[2] - m*(x2-p[1]))*(y1 - p[2] - m*(x1-p[1])) < 0) 
            if (m*p[1]*x1 - p[2]*x1 - m*p[1]*x2 + p[2]*x2 - x2*y1 + x1*y2) / 
                (m*x1 - m*x2 - y1 + y2)  - p[1] > 0
                cntr += 1
            end
        end
    end
    return isodd(cntr)    
end

import Interpolations.interpolate
function interpolate(h::Array{T,2}) where T <: Real
    return interpolate(h,
                       Interpolations.BSpline(Interpolations.Linear()),
                       Interpolations.OnGrid())
end

import Base.getindex 
getindex(h::Interpolations.BSplineInterpolation,
         z0::Complex) = h[real(z0),imag(z0)]

"""
Find the flow line of angle θ in the field h. 
In other words, solve the DE η'(t) = exp(ih(η(t))/χ + iθ)". 
"""
function flowline(h::Interpolations.BSplineInterpolation,
                  z0::Complex,
                  χ::Real,
                  θ::Real;
                  δ::Real=0.01,
                  S::Set{Complex}=Set{Complex}())
    (a,b) = size(h.coefs)
    η = [z0]
    while 1.0 ≤ real(η[end]) ≤ a && 1.0 ≤ imag(η[end]) ≤ b
        push!(η, η[end] + δ * exp(im*h[η[end]]/χ + im*θ))
        w = η[end]
        for z in S
            if abs2(z-w) < 1e-3
                return η
            end
        end
    end
    return η
end

flowline(h::Array{Float64,2},
         z0::Complex{Float64},
         χ::AbstractFloat,
         θ::AbstractFloat;
         δ::AbstractFloat=0.01,
         S::Set{Complex{Float64}}=Set()) = flowline(interpolate(h),z0,χ,θ,δ,S)

end # module


