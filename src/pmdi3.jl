using DelimitedFiles
using Distributions
using IterTools
using NonUniformRandomVariateGeneration
using Printf
using Random
using SpecialFunctions
using Statistics
using StatsBase

"""
`pmdi3(dataFiles, dataTypes, N::Int64, particles::Int64,
ρ::Float64, iter::Int64, outputFile::String, initialise::Bool,
output_freq::Int64)`
Runs particleMDI on specified datasets
## Input
- `dataFiles::Vector` a vector of K data matrices to be analysed
- `dataTypes::Vector` a vector of K datatypes. Independent multivariate normals can be
specified with `particleMDI.gaussianCluster`
- `N::Int64` the maximum number of clusters to fit
- `particles::Int64` the number of particles
- `ρ::Float64` proportion of allocations assumed known in each MCMC iteration
- `iter::Int64` number of iterations to run
- `outputFile::String` specification of a CSV file to store output
- `thin::Int64` how frequently should observations be stored to file. `thin = 2` will store every other observation. Default is `thin = 1` (no thinning)
- `featureSelect::Union{String, Nothing}` If `== nothing` feature selection will not be performed. Otherwise, specify a .csv file whil will record feature selection indicators for each dataset.
- `dataNames` if `== nothing` dataset names will be assigned. Otherwise pass a vector of strings labelling each dataset.
## Output
Outputs a .csv file, each row containing:
- Mass parameter for datasets `1:K`
- Φ value for `binomial(K, 2)` pairs of datasets
- c cluster allocations for observations `1:n` in datasets `1:k`
If featureSelect is specified also outputs a .csv file, each row containing:
- Binary flag indicating feature selection for each feature in each dataset for each iteration
"""
function pmdi3(dataFiles, dataTypes, N::Int64, particles::Int64,
    ρ::Float64, iter::Int64, outputFile::String;
     thin::Int64 = 1,
     featureSelect::Union{String, Nothing} = nothing,
     dataNames = nothing)

    K       = length(dataFiles) # No. of datasets
    n_obs   = size(dataFiles[1], 1)

    # Set names if not specified
    if dataNames == nothing
        dataNames = ["K$i" for i in 1:K]
    end

    @assert length(dataTypes) == K "Number of datatypes not equal to number of datasets"
    @assert length(dataNames) == K "Number of data names not equal to number of datasets"
    @assert all(x->x==n_obs, [size(dataFiles[k])[1] for k = 1:K]) "Datasets don't have same number of observations. Each row must correspond to the same underlying observational unit across datasets."
    @assert (ρ < 1) && (ρ > 0) "ρ must be between 0 and 1"
    @assert (N <= n_obs) & (N > 1) "Number of clusters must be greater than 1 and not greater than the number of observations, suggest using floor(log(n)) = $(floor(Int64, log(n_obs)))"
    @assert particles > 1 "Conditional particle filter requires 2 or more particles"


    # Initialise the hyperparameters
    M = ones(Float64, K) .* 2 # Mass parameter
    γc = rand(Gamma(1.0 / N, 1), N, K) .+ eps(Float64) # Component weights
    Φ = K > 1 ? rand(Gamma(1, 0.2), Int64(K * (K - 1) * 0.5)) : zeros(1) # Dataset concordance measure

    # Initialise allocations randomly according to γc
    s = Matrix{Int64}(undef, n_obs, K)
    for k = 1:K
        s[:, k] = sampleCategorical(n_obs, γc[:, k])
    end

    # Get a matrix of all combinations of allocations
    c_combn = Matrix{Int64}(undef, N ^ K, K)
    for k in 1:K
        c_combn[:, K - k + 1] = div.(0:(N ^ K - 1), N ^ (K - k)) .% N .+ 1
    end

    # The corresponding gammas
    Γc = Matrix{Float64}(undef, N ^ K, K)
    for k = 1:K
        Γc[:, k] = log.(γc[:, k][c_combn[:, k]])
    end

    # Which Φ value is activated by each of the above combinations
    Φ_index = K > 1 ? Matrix{Bool}(undef, N ^ K, Int64(K * (K - 1) / 2)) : fill(1, (N, 1))
    if K > 1
        i = 1
        for k1 in 1:(K - 1)
            for k2 in (k1 + 1):K
                Φ_index[:, i] = (c_combn[:, k1] .== c_combn[:, k2])
                i += 1
            end
        end
    end

    # Normalising constant
    Z = update_Z(Φ, Φ_index, Γc)
    v = update_v(n_obs, Z)

    # Feature selection index
    featureFlag = [rand(Bool, size(dataFiles[k], 2)) for k in 1:K]
    if featureSelect == nothing
        for k in 1:K
            featureFlag[k] .= true
        end
    else
        featureNames = ["$(dataNames[k])_d$d" for k in 1:K for d in 1:size(dataFiles[k], 2)]
        writedlm(featureSelect, reshape(featureNames, 1, length(featureNames)), ',')
        featureFile = open(featureSelect, "a")
        writedlm(featureFile, [featureFlag...;]', ',')
    end


    # Feature select probabilities
    featureProb = [zeros(Float64, size(dataFiles[k], 2)) for k in 1:K]
    featureNull = [zeros(Float64, size(dataFiles[k], 2)) for k in 1:K]
    nullCluster = [dataTypes[k](dataFiles[k]) for k in 1:K]
    for k = 1:K
        for i = 1:n_obs
            cluster_add!(nullCluster[k], dataFiles[k][i, :], ones(Bool, size(dataFiles[k], 2)))
        end
        featureNull[k] = - calc_logmarginal(nullCluster[k])
    end

    # Set up storage for particle information
    # particle matches the cluster labels to the cluster IDs
    particle = [[Particle(n_obs, N)] for k in 1:K]
    for k in 1:K
        particle[k][1].ndescendants = particles
    end
    # How many particles does this particle equate to?
    num_particles = [zeros(Int, K)]
    # Particle weights
    logweight = zeros(Float64, particles, K)
    # A vector containing all of the clusters
    clusters = [[dataTypes[k](dataFiles[k])] for k in 1:K]
    # How many particles is this cluster present in?
    # Is this cluster available?
    cluster_free = [ones(Bool, N * particles + 1) for k in 1:K]
    # logprob is prob of assigning obs to cluster in respective position
    logprob = [Vector{Float64}(undef, N * particles + 1) for k in 1:K]
    fprob = Vector{Float64}(undef, N)
    descendants = zeros(Int, particles)

    # sstar_id = Matrix{Int64}(undef, particles, K)
    # sstar = zeros(Int64, particles, n_obs, K)
    out = [map(x -> @sprintf("MassParameter_%d", x), 1:K);
               map((x, y) -> @sprintf("phi_%d_%d", x, y),
               calculate_Φ_lab(K)[:, 1],
               calculate_Φ_lab(K)[:, 2]);
               "ll";
               ["$(dataNames[k])_n$i" for k in 1:K for i in 1:n_obs]]
    out =  reshape(out, 1, length(out))
    writedlm(outputFile, out, ',')
    fileid = open(outputFile, "a")
    ll = 0
    ll1 = time_ns()
    writedlm(fileid, [M; Φ; ll;  s[1:(n_obs * K)]]', ',')

    order_obs = collect(1:n_obs)
    n1 = floor(Int64, ρ * n_obs)

    for it in 1:iter
        #for i in eachindex(particle)
        #    particle[i] = 1
        #end
        shuffle!(order_obs)

        # Update hyperparameters
        if K > 1
            update_Φ!(Φ, v, s, Φ_index, γc, K, Γc)
        end
        update_γ!(γc, Φ, v, M, s, Φ_index, c_combn, Γc, N, K)
        Π = γc ./ sum(γc, dims = 1)
        Z = update_Z(Φ, Φ_index, Γc)
        v = update_v(n_obs, Z)
        update_M!(M, γc, K, N)

        log_γ = log.(γc)

        for k = 1:K
            for i = 1:(N ^ K)
                Γc[i, k] = log_γ[c_combn[i, k], k]
            end
        end


        for k = 1:K
            id = 2
            us = unique(s[order_obs[1:(n1 - 1)], k])
            for u in us
                append!(clusters[k], [dataTypes[k](dataFiles[k])])
                for i in order_obs[1:(n1 - 1)]
                    if s[i, k] == u
                        cluster_add!(clusters[k][id], dataFiles[k][i, :], featureFlag[k])
                        particle[k][1].cluster_IDs[s[i, k]] = id
                        particle[k][1].s[i] = s[i, k]
                        # sstar[1, i, k] = s[i, k]
                    end
                end
                id += 1
            end
        end

        for i in order_obs[n1:n_obs]
            for k in 1:K
                # particle_k = view(particle, :, :, k)
                # logprob_particle = view(logprob, particle_k, k)
                obs = view(dataFiles[k], i, :)
                # logprob_particle_k = view(logprob_particle, :, :, k)
                # sstar_id_k = view(sstar_id, :, k)
                Π_k = view(Π, :, k)
                for (id, cluster) in enumerate(clusters[k])
                    logprob[k][id] = calc_logprob(obs, cluster, featureFlag[k])
                end

                # Draw the new allocations
                for (ind, p) in enumerate(particle[k])
                    # fprob = logprob_particle[:, p]
                    for n in 1:N
                         # fprob[n] = Π[n, k] * exp(fprob[n] - max_logprob)
                         fprob[n] = logprob[k][p.cluster_IDs[n]]
                     end
                     max_logprob = maximum(fprob)
                     for n in 1:N
                         fprob[n] -= max_logprob
                         fprob[n] = exp(fprob[n])
                         fprob[n] *= Π_k[n]
                    end
                    p.ξ += log(sum(fprob)) + max_logprob
                    # Set reference trajectory
                    descendants[1:p.ndescendants] = sample(1:N, Weights(fprob), p.ndescendants)
                    if ind == 1
                        descendants[1] = s[i, k]
                    end
                    curr_descendant = descendants[1]
                    for des in 2:p.ndescendants
                        if descendants[des] != curr_descendant
                            curr_descendant = descendants[des]
                            new_p = deepcopy(p)
                            new_p.n
                            append!(particle[k], [p])
                        end
                    end
                    return particle[k]
                    sstar[p, i, k] = new_s
                end

                # Add observation to new cluster
                max_k = maximum(particle_k)
                for p in unique(sstar_id_k)
                    if wipedout(particle_k, sstar_id_k, p)
                        # If the origin cluster still exists somewhere
                        # Need to create a new cluster
                        # with obs added to it
                        id = p
                    else
                        id = max_k + 1
                        clusters[k][id] = deepcopy(clusters[k][p])
                        max_k += 1
                    end
                    cluster_add!(clusters[k][id], obs, featureFlag[k])
                    for part in 1:particles
                        if particle[sstar[part, i, k], part, k] == p
                            particle[sstar[part, i, k], part, k] = id
                        end
                    end
                end
            end
            if K > 1
                Φ_upweight!(logweight, sstar[:, i, :], K, Φ, particles)
            end

            # Resampling
            if calc_ESS(logweight) <= 0.5 * particles
                partstar = draw_partstar(logweight, particles)
                logweight .= 1.0
                for k in 1:K
                    particle[:, :, k] = particle[:, partstar, k]
                    for (i, id) in enumerate(1:(maximum(particle[:, :, k])))
                        if id !== i
                            particle_k = view(particle, :, :, k)
                            for j in eachindex(particle_k)
                                if particle_k[j] == id
                                    particle_k[j] = i
                                end
                            end
                            clusters[k][i] = deepcopy(clusters[k][id])
                        end
                    end
                end
            end
        end

        # Select a single particle
        p_weights = similar(logweight)
        max_logweight = maximum(logweight)
        for i in eachindex(p_weights)
            p_weights[i] = exp(logweight[i] - max_logweight)
        end
        p_star = sample(1:particles, Weights(p_weights))

        # Feature selection
        ## Create a null particle with every obs in one cluster
        if featureSelect != nothing
            ## Compare this to the marginal likelihood for each cluster
            for k = 1:K
                featureProb[k] = featureNull[k] .+ 0
                occupiedClusters = unique(sstar[p_star, :, k])
                for clust in occupiedClusters
                    clust_members = findindices(sstar[p_star, :, k], clust)
                    clust_params = dataTypes[k](dataFiles[k])
                    for obs in clust_members
                        cluster_add!(clust_params, dataFiles[k][obs, :], ones(Bool, size(dataFiles[k], 2)))
                    end
                    featureProb[k] += calc_logmarginal(clust_params)
                end
                featureFlag[k] = (1 .- 1 ./ (exp.(featureProb[k] .+ 1))) .> rand(length(featureProb[k]))
                # featurePosterior[k] += featureFlag[k] ./ (iter + 1)
            end
        end

        logweight .= 1.0
        s[:] = sstar[p_star, :, :]
        # Match up labels across datasets
        align_labels!(s, Φ, γc, N, K)

        ll = (time_ns() - ll1) / 1.0e9
        if it % thin == 0
            writedlm(fileid, [M; Φ; ll; s[1:(n_obs * K)]]', ',')
            if featureSelect != nothing
                writedlm(featureFile, [featureFlag...;]', ',')
            end
        end
    end
    close(fileid)
    if featureSelect != nothing
        close(featureFile)
    end
    return
end