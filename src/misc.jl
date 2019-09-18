@inline function calculate_Φ_lab(K::Int)
    Φ_lab = K > 1 ? Matrix{Int}(undef, binomial(K, 2), 2) : [1 1]
    if K > 1
        i = 1
        for k1 in 1:(K - 1)
            for k2 in (k1 + 1):K
                Φ_lab[i, :] = [k1, k2]
                i += 1
            end
        end
    end
    return Φ_lab
end

@inline function calc_ESS(logweight)
    ESSnum = 0.0
    ESSdenom = 0.0
    max_l = maximum(logweight)
    for l in logweight
        num = exp(l - max_l)
        ESSnum += num
        ESSdenom += num ^ 2
    end
    return (ESSnum ^ 2) / ESSdenom
end

function draw_partstar(logweight, particles)
    u = rand() / particles
    pprob = cumsum(exp.(logweight .- maximum(logweight)))
    partstar = zeros(Int, particles)
    i = 0
    for p = 1:particles
        while pprob[p] / last(pprob) >= u
            u += 1 / particles
            i += 1
            partstar[i] = p
        end
    end
    # Systematic resampling not ideal for CSMC
    # Particle indices are sorted, so can't just set
    # the first as reference trajectory
    # Instead: shuffle, replace first, sort
    shuffle!(partstar)
    partstar[1] = 1
    sort!(partstar)
    return partstar
end


function Φ_upweight!(logweight, sstar, K::Int, Φ, particles)
    Φ_lab = calculate_Φ_lab(K)
    for i in 1:binomial(K, 2)
        Φ_log = log(1 + Φ[i])
        for p in 1:particles
            logweight[p] += (sstar[p, Φ_lab[i, 1]] == sstar[p, Φ_lab[i, 2]]) * Φ_log
        end
    end
    return
end

function align_labels!(s::Array, Φ::Array, γ::Array, N::Int, K::Int)
    K == 1 && return
    Φ_lab = calculate_Φ_lab(K)
    Φ_log = log.(Φ .+ 1)
    # unique_s = unique(s)
    # No need to permute labels for dataset 1
    @inbounds for k = 1:K
        occupied = unique(s[:, k])
        relevant_Φs = Φ_log[(Φ_lab[:, 1] .== k) .| (Φ_lab[:, 2] .== k)]
        for label in occupied
            label_ind  = s[:, k] .== label
            all(label_ind .== false) && continue
            label_rows = s[label_ind, setdiff2(K, k)]
            # Only consider most frequent label in each other dataset
            # as this will always dominate others
            # and saves time
            # However, detailed balance?
            for new_label in 1:N # mapslices(mode, label_rows, dims = 1)
                new_label == label && continue
                new_label_ind   = s[:, k] .== new_label
                new_label_rows  = s[new_label_ind, setdiff2(K, k)]
                log_phi_sum     = sum(count_equals(label_rows, label) .* relevant_Φs + count_equals(new_label_rows, new_label) .* relevant_Φs)
                log_phi_sum_swap = sum(count_equals(label_rows, new_label) .* relevant_Φs + count_equals(new_label_rows, label) .* relevant_Φs)
                accept = exp(log_phi_sum_swap - log_phi_sum)
                if rand() < accept
                    s[label_ind, k]        .= new_label
                    s[new_label_ind, k]    .= label
                    γ[new_label, k], γ[label, k] = γ[label, k], γ[new_label, k]
                    label = new_label
                    label_ind  = s[:, k] .== label
                    label_rows = s[label_ind, setdiff2(K, k)]
                end
            end
        end
    end
end

@inline function count_equals(A::Array, b::Int)
    out = zeros(Float64, size(A, 2))
    for i in 1:size(A, 1)
        for j in 1:size(A, 2)
            if A[i, j] == b
                out[j] += 1.
            end
        end
    end
    return out
end


@inline function setdiff2(K::Int, b::Int)
    # Specifically find diff between set 1:K and
    # integer b
    out = ones(Bool, K)
    out[b] = 0
    return out
end

@inline function find_logical(A::Vector, b::Int)
    # Return a bit-array indicating where A has value b
    out = zeros(Bool, size(A, 1))
    for i in eachindex(A)
        if A[i] == b
            out[i] = true
        end
    end
    return out
end


@inline function findindex(A, b)
    # Find first occurrence of b in A
    for (i,a) in enumerate(A)
        if a == b
            return i
        end
    end
end

@inline function findindices(A, b)
    # Find all occurrences of b in A
    # Specifically for finding occurrences of gamma
    out = Int[]
    for (i, a) in enumerate(A)
        if a == b
            push!(out, i)
        end
    end
    return out
end

function findZindices(k, K, n, N)
    # Instead of searching where the γc_combn = a
    # by searching the vector
    # We can know this in advance
    # This way is >10x faster for larger problems
    out = zeros(Int, N ^ (K - 1))
    start = (n - 1) * N ^ (k - 1) + 1
    ind = 1
    for i in 1:(N ^ (K - k))
        for j in start:(start - 1 + N ^ (k - 1))
            out[ind] = j
            ind += 1
        end
        start += N ^ k
    end
    return out
end

function countn(A, b)
    out = 0
    for a in A
        if a == b
            out += 1
        end
    end
    return out
end

function wipedout0(v1, v2, x)
    # Is the number of occurrences of x greater in
    # v2 than v1?
    if x == 1
        return false
    end
    count1 = 0
    @inbounds for v in v2
        if v == x
            count1 += 1
        end
    end
    for j in 1:size(v1, 2)
    @inbounds for i in 1:size(v1, 1)
            if v1[i, j] == x
                count1 -= 1
                if count1 < 0
                    return false
                else
                    break
                end
            end
        end
    end
    return true
end

function wipedout(v1, v2, x)
    return count(y -> y == x, v2) >= count(y -> y == x, v1)
end

@inline function canonicalise_IDs!(IDs)
    tmp = view(IDs, sortperm(IDs))
    current = - 1
    count = 0
    # tmp[1] = count
    for (i, u) in enumerate(tmp)
        if u != current
            count += 1
            current = u
        end
        tmp[i] = count
    end
end


function draw_uniform_sorted(n)
    @assert n != 0 "WTF"
    u = rand(n)
    u[n] = exp(log(u[n]) / n)
    for i in (n - 1):-1:1
        u[i] = exp(log(u[i]) / i) * u[i + 1]
    end
    return u
end
