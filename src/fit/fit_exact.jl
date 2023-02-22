# Fast fitting for exact observations
function loglik_exact(Y, gate, model)

    # By dimension, then by component
    expert_ll_dim_comp = expert_ll_list_exact(Y, model)

    # Aggregate by dimension
    expert_ll_comp = loglik_aggre_dim(expert_ll_dim_comp)

    # Adding the gating function
    gate_expert_ll_comp = loglik_aggre_gate_dim(gate, expert_ll_comp)

    # Aggregate by component
    gate_expert_ll = loglik_aggre_gate_dim_comp(gate_expert_ll_comp)

    # Normalize by tn & tn_bar
    norm_gate_expert_ll = gate_expert_ll

    # Sum over all observations
    ll = sum(norm_gate_expert_ll)

    return (expert_ll_dim_comp=expert_ll_dim_comp,
        expert_ll_comp=expert_ll_comp,
        gate_expert_ll_comp=gate_expert_ll_comp,
        gate_expert_ll=gate_expert_ll,
        norm_gate_expert_ll=norm_gate_expert_ll,
        ll=ll,
    )
end

function fit_exact(Y, X, α_init, model;
    exposure=nothing,
    penalty=true, pen_α=5.0, pen_params=nothing,
    ϵ=1e-03, α_iter_max=5.0, ecm_iter_max=200,
    grad_jump=true, grad_seq=nothing,
    print_steps=1)
    # Make variables accessible within the scope of `let`
    let α_em, gate_em, model_em, model_em_expo, ll_em_list, ll_em, ll_em_np, ll_em_old,
        ll_em_np_old, iter, z_e_obs, z_e_lat, k_e, params_old
        # Initial loglik
        gate_init = LogitGating(α_init, X)
        model_expo = exposurize_model(model; exposure=exposure) # exposurize
        ll_np_list = loglik_exact(Y, gate_init, model_expo)
        ll_init_np = ll_np_list.ll
        ll_penalty =
            penalty ? (penalty_α(α_init, pen_α) + penalty_params(model, pen_params)) : 0.0
        ll_init = ll_init_np + ll_penalty

        if (print_steps > 0)
            @info("Initial loglik: $(ll_init_np) (no penalty), $(ll_init) (with penalty)")
        end

        # start em
        α_em = copy(α_init)
        model_em = copy(model)
        model_em_expo = exposurize_model(model_em; exposure=exposure)
        gate_em = LogitGating(α_em, X)
        ll_em_list = loglik_exact(Y, gate_em, model_em_expo)
        ll_em_np = ll_em_list.ll
        ll_em = ll_init
        ll_em_old = -Inf
        iter = 0

        while (ll_em - ll_em_old > ϵ) & (iter < ecm_iter_max)
            # Update counter and loglikelihood
            iter = iter + 1
            ll_em_np_old = ll_em_np
            ll_em_old = ll_em

            # E-Step
            z_e_obs = exp.(ll_em_list.gate_expert_ll_comp .- ll_em_list.gate_expert_ll)
            z_e_lat = fill(1 / size(model)[2], size(X)[1], size(model)[2])
            # k_e = EM_E_k(ll_em_list.gate_expert_tn)
            k_e = fill(0.0, size(X)[1])

            # M-Step: α
            ll_em_temp = ll_em
            α_em = EM_M_α(
                X,
                α_em,
                z_e_obs,
                z_e_lat,
                k_e;
                α_iter_max=α_iter_max,
                penalty=penalty,
                pen_α=pen_α,
            )
            gate_em = LogitGating(α_em, X)
            ll_em_list = loglik_exact(Y, gate_em, model_em_expo)
            ll_em_np = ll_em_list.ll
            ll_em_penalty = if penalty
                (penalty_α(α_em, pen_α) + penalty_params(model_em, pen_params))
            else
                0.0
            end
            ll_em = ll_em_np + ll_em_penalty

            s = ll_em - ll_em_temp > 0 ? "+" : "-"
            pct = abs((ll_em - ll_em_temp) / ll_em_temp) * 100
            if (print_steps > 0) && (iter % print_steps == 0)
                @info(
                    "Iteration $(iter), updating α: $(ll_em_old) ->  $(ll_em), ( $(s) $(pct) % )"
                )
            end
            ll_em_temp = ll_em

            # M-Step: component distributions
            for j in 1:size(model)[1] # by dimension
                # for j in 1:1
                for k in 1:size(model)[2] # by component
                    params_old = params(model_em[j, k])

                    model_em[j, k] = EM_M_expert_exact(model_em[j, k],
                        Y[:, j], exposure,
                        # ll_em_list.expert_ll_pos_dim_comp[j][:,k],
                        # ll_em_list.expert_ll_dim_comp[j, k, :],
                        vec(z_e_obs[:, k]);
                        penalty=penalty, pen_pararms_jk=pen_params[j][k])

                    model_em_expo = exposurize_model(model_em; exposure=exposure)
                    ll_em_list = loglik_exact(Y, gate_em, model_em_expo)
                    ll_em_np = ll_em_list.ll
                    ll_em_penalty = if penalty
                        (penalty_α(α_em, pen_α) + penalty_params(model_em, pen_params))
                    else
                        0.0
                    end
                    ll_em = ll_em_np + ll_em_penalty

                    if (print_steps > 0) && (iter % print_steps == 0)
                        s = ll_em - ll_em_temp > 0 ? "+" : "-"
                        pct = abs((ll_em - ll_em_temp) / ll_em_temp) * 100
                        @info(
                            "Iteration $(iter), updating model[$j, $k]: $(ll_em_temp) ->  $(ll_em), ( $(s) $(pct) % )"
                        )
                        if s == "-"
                            @info(
                                "Intended update of params: $(params_old) ->  $(params(model_em[j,k]))"
                            )
                        end
                    end
                    ll_em_temp = ll_em
                end
            end

            α_em = α_em
            model_em = model_em
            model_em_expo = exposurize_model(model_em; exposure=exposure)
            gate_em = LogitGating(α_em, X)
            ll_em_list = loglik_exact(Y, gate_em, model_em_expo)
            ll_em_np = ll_em_list.ll
            ll_em_penalty = if penalty
                (penalty_α(α_em, pen_α) + penalty_params(model_em, pen_params))
            else
                0.0
            end
            ll_em = ll_em_np + ll_em_penalty
        end

        converge = (ll_em - ll_em_old > ϵ) ? false : true
        AIC = -2.0 * ll_em_np + 2 * (_count_α(α_em) + _count_params(model_em))
        BIC = -2.0 * ll_em_np + log(size(Y)[1]) * (_count_α(α_em) + _count_params(model_em))

        return (α_fit=α_em, model_fit=model_em,
            converge=converge, iter=iter,
            ll_np=ll_em_np, ll=ll_em,
            AIC=AIC, BIC=BIC)
    end
end
