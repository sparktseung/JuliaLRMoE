"""
    GammaCountExpert(m, s)

Expert function: `GammaCountExpert(m, s)`.

"""
struct GammaCountExpert{T<:Real} <: NonZIDiscreteExpert
    m::T
    s::T
    GammaCountExpert{T}(m, s) where {T<:Real} = new{T}(m, s)
end

function GammaCountExpert(m::T, s::T; check_args=true) where {T <: Real}
    check_args && @check_args(GammaCountExpert, m > zero(m) && s > zero(s))
    return GammaCountExpert{T}(m, s)
end

## Outer constructors
GammaCountExpert(m::Real, s::Real) = GammaCountExpert(promote(m, s)...)
GammaCountExpert(m::Integer, s::Integer) = GammaCountExpert(float(m), float(s))

## Conversion
function convert(::Type{GammaCountExpert{T}}, m::S, s::S) where {T <: Real, S <: Real}
    GammaCountExpert(T(m), T(s))
end
function convert(::Type{GammaCountExpert{T}}, d::GammaCountExpert{S}) where {T <: Real, S <: Real}
    GammaCountExpert(T(d.m), T(d.s), check_args=false)
end
copy(d::GammaCountExpert) = GammaCountExpert(d.m, d.s, check_args=false)

## Loglikelihood of Expoert
logpdf(d::GammaCountExpert, x...) = isinf(x...) ? -Inf : Distributions.logpdf.(LRMoE.GammaCount(d.m, d.s), x...)
pdf(d::GammaCountExpert, x...) = isinf(x...) ? 0.0 : Distributions.pdf.(LRMoE.GammaCount(d.m, d.s), x...)
logcdf(d::GammaCountExpert, x...) = isinf(x...) ? 0.0 : Distributions.logcdf.(LRMoE.GammaCount(d.m, d.s), x...)
cdf(d::GammaCountExpert, x...) = isinf(x...) ? 1.0 : Distributions.cdf.(LRMoE.GammaCount(d.m, d.s), x...)

## Parameters
params(d::GammaCountExpert) = (d.m, d.s)

## Simululation
sim_expert(d::GammaCountExpert, sample_size) = Distributions.rand(LRMoE.GammaCount(d.m, d.s), sample_size)

## penalty
penalty_init(d::GammaCountExpert) = [1.0 Inf 1.0 Inf]
penalize(d::GammaCountExpert, p) = (p[1]-1)*log(d.m) - d.m/p[2] + (p[3]-1)*log(d.s) - d.s/p[4]

## Misc functions for E-Step

function _sum_dens_series(m_new, s_new, d::GammaCountExpert, yl, yu)
    upper_finite = isinf(yu) ? Distributions.quantile(GammaCount(d.m, d.s), 1-1e-10) : yu
    series = yl:(max(yl, min(yu, upper_finite+1)))
    return sum(logpdf.(GammaCountExpert(m_new, s_new), series) .* pdf.(d, series))[1]
end

function _int_obs_dens_raw(m_new, s_new, d::GammaCountExpert, yl, yu)
    return _sum_dens_series(m_new, s_new, d, yl, yu)
end

function _int_lat_dens_raw(m_new, s_new, d::GammaCountExpert, tl, tu)
    return (tl==0 ? 0.0 : _sum_dens_series.(m_new, s_new, d, 0, ceil(tl)-1)) + (isinf(tu) ? 0.0 : _sum_dens_series.(m_new, s_new, d, floor(tu)+1, Inf))
end


function _gammacount_optim_params(lognew,
                        d_old,
                        tl, yl, yu, tu,
                        expert_ll_pos, expert_tn_pos, expert_tn_bar_pos,
                        z_e_obs, z_e_lat, k_e; # ,
                        # Y_e_obs, Y_e_lat;
                        penalty = true, pen_pararms_jk = [1.0 Inf 1.0 Inf])
    # Optimization in log scale for unconstrained computation    
    m_tmp = exp(lognew[1])
    s_tmp = exp(lognew[2])

    # Further E-Step
    yl_yu_unique = unique_bounds(yl, yu)
    int_obs_dens_tmp = _int_obs_dens_raw.(m_tmp, s_tmp, d_old, yl_yu_unique[:,1], yl_yu_unique[:,2])
    densY_e_obs = exp.(-expert_ll_pos) .* int_obs_dens_tmp[match_unique_bounds(hcat(vec(yl), vec(yu)), yl_yu_unique)]
    nan2num(densY_e_obs, 0.0) # get rid of NaN

    tl_tu_unique = unique_bounds(tl, tu)
    int_lat_dens_tmp = _int_lat_dens_raw.(m_tmp, s_tmp, d_old, tl_tu_unique[:,1], tl_tu_unique[:,2])
    densY_e_lat = exp.(-expert_tn_bar_pos) .* int_lat_dens_tmp[match_unique_bounds(hcat(vec(tl), vec(tu)), tl_tu_unique)]
    nan2num(densY_e_lat, 0.0) # get rid of NaN

    # term_zkz = z_e_obs .+ (z_e_lat .* k_e)
    term_zkz_Y = (z_e_obs .* densY_e_obs) .+ (z_e_lat .* k_e .* densY_e_lat)

    # sum_term_zkz = sum(term_zkz)[1]
    sum_term_zkzy = sum(term_zkz_Y)[1]

    obj = sum_term_zkzy
    p = penalty ? (pen_pararms_jk[1]-1)*log(m_tmp) - m_tmp/pen_pararms_jk[2] + (pen_pararms_jk[3]-1)*log(s_tmp) - s_tmp/pen_pararms_jk[4] : 0.0
    return (obj + p) * (-1.0)
end

## EM: M-Step
function EM_M_expert(d::GammaCountExpert,
                    tl, yl, yu, tu,
                    expert_ll_pos,
                    expert_tn_pos,
                    expert_tn_bar_pos,
                    z_e_obs, z_e_lat, k_e;
                    penalty = true, pen_pararms_jk = [1.0 Inf 1.0 Inf])

    # Update parameters
    logparams_new = Optim.minimizer( Optim.optimize(x -> _gammacount_optim_params(x, d,
                                                tl, yl, yu, tu,
                                                expert_ll_pos, expert_tn_pos, expert_tn_bar_pos,
                                                z_e_obs, z_e_lat, k_e,
                                                # Y_e_obs, Y_e_lat,
                                                penalty = penalty, pen_pararms_jk = pen_pararms_jk),
                                                # [log(d.m)-2.0, log(d.s)-2.0],
                                                # [log(d.m)+2.0, log(d.s)+2.0],
                                                [log(d.m), log(d.s)] ))
    # println("$logparams_new")
    m_new = exp(logparams_new[1])
    s_new = exp(logparams_new[2])

    # println("$m_new, $s_new")

    return GammaCountExpert(m_new, s_new)

end

## EM: M-Step, exact observations
function _gammacount_optim_params(lognew,
                        d_old,
                        ye, # tl, yl, yu, tu,
                        expert_ll_pos, # expert_tn_pos, expert_tn_bar_pos,
                        z_e_obs; # , # z_e_lat, k_e,
                        # Y_e_obs, Y_e_lat;
                        penalty = true, pen_pararms_jk = [1.0 Inf 1.0 Inf])
    # Optimization in log scale for unconstrained computation    
    m_tmp = exp(lognew[1])
    s_tmp = exp(lognew[2])

    # Further E-Step
    # yl_yu_unique = unique_bounds(yl, yu)
    # int_obs_dens_tmp = _int_obs_dens_raw.(m_tmp, s_tmp, d_old, yl_yu_unique[:,1], yl_yu_unique[:,2])
    densY_e_obs = logpdf.(GammaCountExpert(m_tmp, s_tmp), ye) # exp.(-expert_ll_pos) .* int_obs_dens_tmp[match_unique_bounds(hcat(vec(yl), vec(yu)), yl_yu_unique)]
    nan2num(densY_e_obs, 0.0) # get rid of NaN

    # tl_tu_unique = unique_bounds(tl, tu)
    # int_lat_dens_tmp = _int_lat_dens_raw.(m_tmp, s_tmp, d_old, tl_tu_unique[:,1], tl_tu_unique[:,2])
    densY_e_lat = 0.0 # exp.(-expert_tn_bar_pos) .* int_lat_dens_tmp[match_unique_bounds(hcat(vec(tl), vec(tu)), tl_tu_unique)]
    # nan2num(densY_e_lat, 0.0) # get rid of NaN

    # term_zkz = z_e_obs .+ (z_e_lat .* k_e)
    term_zkz_Y = (z_e_obs .* densY_e_obs) # .+ (z_e_lat .* k_e .* densY_e_lat)

    # sum_term_zkz = sum(term_zkz)[1]
    sum_term_zkzy = sum(term_zkz_Y)[1]

    obj = sum_term_zkzy
    p = penalty ? (pen_pararms_jk[1]-1)*log(m_tmp) - m_tmp/pen_pararms_jk[2] + (pen_pararms_jk[3]-1)*log(s_tmp) - s_tmp/pen_pararms_jk[4] : 0.0
    return (obj + p) * (-1.0)
end
function EM_M_expert_exact(d::GammaCountExpert,
                    ye,
                    expert_ll_pos,
                    z_e_obs; 
                    penalty = true, pen_pararms_jk = [1.0 Inf 1.0 Inf])

    # Update parameters
    logparams_new = Optim.minimizer( Optim.optimize(x -> _gammacount_optim_params(x, d,
                                                ye, # tl, yl, yu, tu,
                                                expert_ll_pos, # expert_tn_pos, expert_tn_bar_pos,
                                                z_e_obs, # z_e_lat, k_e,
                                                # Y_e_obs, Y_e_lat,
                                                penalty = penalty, pen_pararms_jk = pen_pararms_jk),
                                                # [log(d.m)-2.0, log(d.s)-2.0],
                                                # [log(d.m)+2.0, log(d.s)+2.0],
                                                [log(d.m), log(d.s)] ))

    # println("$logparams_new")
    m_new = exp(logparams_new[1])
    s_new = exp(logparams_new[2])

    # println("$m_new, $s_new")
    return GammaCountExpert(m_new, s_new)

end