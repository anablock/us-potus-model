## Desc
# Refactored version run file

## Setup
#rm(list = ls())
options(mc.cores = 6)
n_chains <- 6
n_cores <- 6
n_sampling <- 500
n_warmup <- 500
n_refresh <- n_sampling*0.1

## Libraries
{
  library(tidyverse, quietly = TRUE)
  library(rstan, quietly = TRUE)
  library(stringr, quietly = TRUE)
  library(lubridate, quietly = TRUE)
  library(gridExtra, quietly = TRUE)
  library(pbapply, quietly = TRUE)
  library(parallel, quietly = TRUE)
  library(boot, quietly = TRUE)
  library(lqmm, quietly = TRUE) 
  library(gridExtra, quietly = TRUE)
  library(ggrepel, quietly = TRUE)
}

## Functions
cov_matrix <- function(n, sigma2, rho){
  m <- matrix(nrow = n, ncol = n)
  m[upper.tri(m)] <- rho
  m[lower.tri(m)] <- rho
  diag(m) <- 1
  (sigma2^.5 * diag(n))  %*% m %*% (sigma2^.5 * diag(n))
}

mean_low_high <- function(draws, states, id){
  tmp <- draws
  draws_df <- data.frame(mean = inv.logit(apply(tmp, MARGIN = 2, mean)),
                         high = inv.logit(apply(tmp, MARGIN = 2, mean) + 1.96 * apply(tmp, MARGIN = 2, sd)), 
                         low  = inv.logit(apply(tmp, MARGIN = 2, mean) - 1.96 * apply(tmp, MARGIN = 2, sd)),
                         state = states, 
                         type = id)
  return(draws_df) 
}

check_cov_matrix <- function(mat,wt=state_weights){
  # get diagnoals
  s_diag <- sqrt(diag(mat))
  # output correlation matrix
  cor_equiv <- cov2cor(mat)
  diag(cor_equiv) <- NA
  # output equivalent national standard deviation
  nat_product <- sqrt(t(wt) %*% mat %*% wt) / 4
  
  # print & output
  hist(as_vector(cor_equiv),breaks = 10)
  
  hist(s_diag,breaks=10)
  
  
  print(sprintf('national sd of %s',round(nat_product,4)))
}

## Master variables
RUN_DATE <- ymd("2012-11-06")
#RUN_DATE <- ymd("2012-08-04")

election_day <- ymd("2012-11-06")
start_date <- as.Date("2012-03-01") # Keeping all polls after March 1, 2012


# wrangle polls -----------------------------------------------------------
# read
#setwd(here("data/"))
all_polls <- read_csv('data/all_polls_2012.csv')

# select relevant columns from HufFPost polls
all_polls <- all_polls %>%
  dplyr::select(state, pollster, number.of.observations, mode,population,
                start.date, 
                end.date,
                obama, romney, undecided, other)%>%
  mutate(end.date = mdy(end.date),
         start.date = mdy(start.date)) # %>% mutate(obama = obama + 2, romney = romney - 2)


# make sure we've got nothing from the futuree
all_polls <- all_polls %>%
  filter(ymd(end.date) <= RUN_DATE)

# basic mutations
df <- all_polls %>% 
  tbl_df %>%
  rename(n = number.of.observations) %>%
  mutate(begin = ymd(start.date),
         end   = ymd(end.date),
         t = end - (1 + as.numeric(end-begin)) %/% 2) %>%
  filter(t >= start_date & !is.na(t)
         & n > 1) 

# pollster mutations
df <- df %>%
  mutate(pollster = str_extract(pollster, pattern = "[A-z0-9 ]+") %>% sub("\\s+$", "", .),
         pollster = replace(pollster, pollster == "Fox News", "FOX"), # Fixing inconsistencies in pollster names
         pollster = replace(pollster, pollster == "WashPost", "Washington Post"),
         pollster = replace(pollster, pollster == "ABC News", "ABC"),
         undecided = ifelse(is.na(undecided), 0, undecided),
         other = ifelse(is.na(other), 0, other))

# vote shares etc
df <- df %>%
  mutate(two_party_sum = obama + romney,
         polltype = as.integer(as.character(recode(population, 
                                                   "Likely Voters" = "0", 
                                                   "Registered Voters" = "1",
                                                   "Adults" = "2"))), 
         n_respondents = round(n),
         # obama
         n_obama = round(n * obama/100),
         pct_obama = obama/two_party_sum,
         # romney
         n_romney = round(n * romney/100),
         pct_romney = romney/two_party_sum,
         # third-party
         n_other = round(n * other/100),
         p_other = other/100)

# Numerical indices passed to Stan for states, days, weeks, pollsters
state_abb_list <- read.csv("data/potus_results_76_16.csv") %>%
  pull(state) %>% unique()

df <- df %>% 
  mutate(poll_day = t - min(t) + 1,
         # Factors are alphabetically sorted: 1 = --, 2 = AL, 3 = AK, 4 = AZ...
         index_s = as.numeric(factor(as.character(state),
                                     levels = c('--',state_abb_list))),  # ensure levels are same as all 50 names in sate_correlation
         index_t = 1 + as.numeric(t) - min(as.numeric(t)),
         index_p = as.numeric(as.factor(as.character(pollster))))  

# selections
df <- df %>%
  arrange(state, t, polltype, two_party_sum) %>% 
  distinct(state, t, pollster, .keep_all = TRUE) %>%
  select(
    # poll information
    state, t, begin, end, pollster, polltype, method = mode, n_respondents, 
    # vote shares
    pct_obama, n_obama, 
    pct_romney, n_romney, 
    p_other, n_other, poll_day, index_s, index_p, index_t) %>%
  mutate(index_s = ifelse(index_s == 1, 52, index_s - 1)) # national index = 51

# useful vectors
all_polled_states <- df$state %>% unique %>% sort

# day indices
first_day <- min(df$begin)
ndays <- max(df$t) - min(df$t)
all_t <- min(df$t) + days(0:(ndays))
all_t_until_election <- min(all_t) + days(0:(election_day - min(all_t)))

# pollster indices
all_pollsters <- levels(as.factor(as.character(df$pollster)))

# getting state contextual information from 2008 --------------------------
# (1) get state_names and EV        
# (2) set priors on mu_b and alpha,
# (3) get state_weights,           
#setwd(here("data/"))
states2008 <- read.csv("data/2008.csv", 
                       header = TRUE, stringsAsFactors = FALSE) %>% 
  mutate(score = obama_count / (obama_count + mccain_count),
         national_score = sum(obama_count)/sum(obama_count + mccain_count),
         delta = score - national_score,
         share_national_vote = (total_count)
         /sum(total_count)) %>%
  arrange(state) 

rownames(states2008) <- states2008$state

# get state incdices
all_states <- states2008$state
state_name <- states2008$state_name
names(state_name) <- states2008$state

# set prior differences
prior_diff_score <- states2008$delta
names(prior_diff_score) <- all_states

# set state weights
state_weights <- c(states2008$share_national_vote / sum(states2008$share_national_vote))
names(state_weights) <- c(states2008$state)

# electoral votes, by state:
ev_state <- states2008$ev
names(ev_state) <- states2008$state

# create covariance matrices ----------------------------------------------
# start by reading in data
state_data <- read.csv("data/potus_results_76_16.csv")
state_data <- state_data %>% 
  select(year, state, dem) %>%
  group_by(state) %>%
  mutate(dem = dem ) %>% #mutate(dem = dem - lag(dem)) %>%
  select(state,variable=year,value=dem)  %>%
  ungroup() %>%
  na.omit() %>%
  filter(variable == 2016)

census <- read.csv('data/acs_2013_variables.csv')
census <- census %>%
  filter(!is.na(state)) %>% 
  select(-c(state_fips,pop_total,pop_density)) %>%
  group_by(state) %>%
  gather(variable,value,
         1:(ncol(.)-1))

state_data <- state_data %>%
  mutate(variable = as.character(variable)) %>%
  bind_rows(census)

# add urbanicity
urbanicity <- read.csv('data/urbanicity_index.csv') %>%
  dplyr::select(state,pop_density = average_log_pop_within_5_miles) %>%
  gather(variable,value,
         2:(ncol(.)))

state_data <- state_data %>%
  bind_rows(urbanicity)

# add pct white evangelical
white_evangel_pct <- read_csv('data/white_evangel_pct.csv') %>%
  gather(variable,value,
         2:(ncol(.)))

state_data <- state_data %>%
  bind_rows(white_evangel_pct)

# add region, as a dummy for each region
regions <- read_csv('data/state_region_crosswalk.csv') %>%
  select(state = state_abb, variable=region) %>%
  mutate(value = 1) %>%
  spread(variable,value)

regions[is.na(regions)] <- 0

regions <- regions %>%
  gather(variable,value,2:ncol(.))

#state_data <- state_data %>%
#  bind_rows(regions)

# scale and spread
state_data_long <- state_data %>%
  group_by(variable) %>%
  # scale all varaibles
  mutate(value = (value - min(value, na.rm=T)) / 
           (max(value, na.rm=T) - min(value, na.rm=T))) %>%
  #mutate(value = (value - mean(value)) / sd(value)) %>%
  # now spread
  spread(state, value) %>% 
  na.omit() %>%
  ungroup() %>%
  select(-variable)

# compute the correlation matrix
# formula is
# a*(lambda*C + (1-lambda)*C_1)
# where C is our correlation matrix with min 0
# and C_1 is a sq matrix with all 1's
# lambda=0 is 100% correlation, lambda=1 is our corr matrix

# save correlation 
C <- cor(state_data_long)  

# increase the baseline correlation of the matrix to correspond to national-level error
C[C < 0] <- 0 # baseline cor for national poll error


tmp_C <- C
diag(tmp_C) <- NA
mean(tmp_C,na.rm=T)

# mixing with matrix of 0.5s
lambda <- 0.75
C_1 <- matrix(data=1,nrow = 51,ncol=51)
a <- 1
new_C <- (lambda*C + (1-lambda)*C_1) %>% make.positive.definite()

tmp <- new_C
diag(tmp) <- NA
mean(tmp,na.rm=T)

state_correlation_polling <- new_C

# make pos definite
state_correlation_polling <- make.positive.definite(state_correlation_polling)

# covariance matrix for polling error
state_covariance_polling_bias <- cov_matrix(51, 0.078^2, 0.9) # 3.4% on elec day
state_covariance_polling_bias <- state_covariance_polling_bias * state_correlation_polling

(sqrt(t(state_weights) %*% state_covariance_polling_bias %*% state_weights) / 4)
mean(apply(MASS::mvrnorm(100,rep(0,51),state_covariance_polling_bias),2,sd) /4) 

# covariance for prior e-day prediction
state_covariance_mu_b_T <- cov_matrix(n = 51, sigma2 = 0.18^2, rho = 0.9) # 6% on elec day
state_covariance_mu_b_T <- state_covariance_mu_b_T * state_correlation_polling

(sqrt(t(state_weights) %*% state_covariance_mu_b_T %*% state_weights) / 4)
mean(apply(MASS::mvrnorm(100,rep(0,51),state_covariance_mu_b_T),2,sd) /4) 

# covariance matrix for random walks
state_covariance_mu_b_walk <- cov_matrix(51, (0.017)^2, 0.9)
state_covariance_mu_b_walk <- state_covariance_mu_b_walk * state_correlation_polling # we want the demo correlations for filling in gaps in the polls

(sqrt(t(state_weights) %*% state_covariance_mu_b_walk %*% state_weights) / 4) * sqrt(300)
mean(apply(MASS::mvrnorm(100,rep(0,51),state_covariance_mu_b_walk),2,sd) /4) * sqrt(300)

## MAKE DEFAULT COV MATRICES
# we're going to make TWO covariance matrix here and pass it
# and 3 scaling values to stan, where the 3 values are 
# (1) the national sd on the polls, (2) the national sd
# on the prior and (3) the national sd of the random walk
# make initial covariance matrix (using specified correlation)
state_covariance_0 <- cov_matrix(51, 0.07^2, 0.9)
state_covariance_0 <- state_covariance_0 * state_correlation_polling # we want the demo correlations for filling in gaps in the polls

# national error of:
sqrt(t(state_weights) %*% state_covariance_0 %*% state_weights) / 4

# save the inital scaling factor
national_cov_matrix_error_sd <- sqrt(t(state_weights) %*% state_covariance_0 %*% state_weights) %>% as.numeric()
national_cov_matrix_error_sd

# save the other scales for later
fit_rmse_day_x <- function(x){0.03 +  (10^-6.6)*(x)^2} # fit to error from external script
fit_rmse_day_x(0:300)
days_til_election <- as.numeric(difftime(election_day,RUN_DATE))
expected_national_mu_b_T_error <- fit_rmse_day_x(days_til_election)

polling_bias_scale <- 0.013 # on the probability scale -- we convert later down
mu_b_T_scale <- expected_national_mu_b_T_error # on the probability scale -- we convert later down
random_walk_scale <- 0.05/sqrt(300) # on the probability scale -- we convert later down

# gen fake matrices, check the math (this is recreated in stan)
national_cov_matrix_error_sd <- sqrt(t(state_weights) %*% state_covariance_0 %*% state_weights) %>% as.numeric()

ss_cov_poll_bias = state_covariance_0 * (polling_bias_scale/national_cov_matrix_error_sd*4)^2
ss_cov_mu_b_T = state_covariance_0 * (mu_b_T_scale/national_cov_matrix_error_sd*4)^2
ss_cov_mu_b_walk = state_covariance_0 * (random_walk_scale/national_cov_matrix_error_sd*4)^2

sqrt(t(state_weights) %*% ss_cov_poll_bias %*% state_weights) / 4 
sqrt(t(state_weights) %*% ss_cov_mu_b_T %*% state_weights) / 4 
sqrt(t(state_weights) %*% ss_cov_mu_b_walk %*% state_weights) / 4 * sqrt(300)



# checking parameters -----------------------------------------------------
par(mfrow=c(3,2), mar=c(3,3,1,1), mgp=c(1.5,.5,0), tck=-.01)
check_cov_matrix(state_covariance_polling_bias)
check_cov_matrix(state_covariance_mu_b_T)
check_cov_matrix(state_covariance_mu_b_walk)

# poll bias should be:
err <- c(0.5, 1.9, 0.8, 7.2, 1.0, 1.4, 0.1, 3.3, 3.4, 0.9, 0.3, 2.7, 1.0) / 2 
sqrt(mean(err^2))

# implied national posterior on e-day
1 / sqrt( 1/((sqrt(t(state_weights) %*% state_covariance_polling_bias %*% state_weights) / 4)^2) + 
            1/((sqrt(t(state_weights) %*% state_covariance_mu_b_T %*% state_weights) / 4)^2) )

# random walks
replicate(1000,cumsum(rnorm(300)*0.5)) %>% 
  as.data.frame() %>%
  mutate(innovation = row_number()) %>%
  gather(walk_number,cumsum,1:100) %>%
  ggplot(.,aes(x=innovation,y=cumsum,group=walk_number)) +
  geom_line() +
  labs(subtitle='normal(0,0.5) random walk')

replicate(1000,cumsum(rt(300,7)*0.5)) %>% 
  as.data.frame() %>%
  mutate(innovation = row_number()) %>%
  gather(walk_number,cumsum,1:100) %>%
  ggplot(.,aes(x=innovation,y=cumsum,group=walk_number)) +
  geom_line() +
  labs(subtitle='student_t(7,0,0.5) random walk')

# create priors -----------------------------------------------------------
# read in abramowitz data
#setwd(here("data/"))
abramowitz <- read.csv('data/abramowitz_data.csv') %>% 
  filter(year < 2012)

# train a caret model to predict demvote with incvote ~ q2gdp + juneapp + year:q2gdp + year:juneapp 
prior_model <- lm(
  incvote ~  juneapp + q2gdp, #+ year:q2gdp + year:juneapp
  data = abramowitz
)

# make predictions
national_mu_prior <- predict(prior_model,newdata = tibble(q2gdp = 1.3,
                                                                juneapp = 1))

# on correct scale
national_mu_prior <- national_mu_prior / 100


# Mean of the mu_b_prior
# 0.486 is the predicted obama share of the national vote according to the Lewis-Beck & Tien model
# https://pollyvote.com/en/components/econometric-models/lewis-beck-tien/
mu_b_prior <- logit(national_mu_prior + prior_diff_score)

# or read in priors if generated already
prior_in <- read_csv("data/state_priors_08_12_16.csv") %>%
  filter(date <= RUN_DATE) %>%
  group_by(state) %>%
  arrange(date) %>%
  filter(date == max(date)) %>%
  select(state,pred) %>%
  ungroup() %>%
  arrange(state)

mu_b_prior <- logit(prior_in$pred + 0.0)
names(mu_b_prior) <- prior_in$state
names(mu_b_prior) == names(prior_diff_score) # correct order?

national_mu_prior <- weighted.mean(inv.logit(mu_b_prior), state_weights)

cat(sprintf('Prior Obama two-party vote is %s\nWith a national sd of %s\n', 
            round(national_mu_prior,3),round(mu_b_T_scale,3)))

# The model uses national polls to complement state polls when estimating the national term mu_a.
# One problem until early September, was that voters in polled states were different from average voters :
# Several solid red states still hadn't been polled, the weighted average of state polls was slightly more pro-obama than national polls.

score_among_polled <- sum(states2008[all_polled_states[-1],]$obama_count)/
  sum(states2008[all_polled_states[-1],]$obama_count + 
        states2008[all_polled_states[-1],]$mccain_count)

alpha_prior <- log(states2008$national_score[1]/score_among_polled)


## polls that adjust for party (not used in 2008-12)
  adjusters <- c(
  "ABC",
  "Washington Post",
  "Ipsos",
  "Pew",
  "YouGov",
  "NBC"
)



# passing data to stan ----------------------------------------------------
N_state_polls <- nrow(df %>% filter(index_s != 52))
N_national_polls <- nrow(df %>% filter(index_s == 52))
T <- as.integer(round(difftime(election_day, first_day)))
current_T <- max(df$poll_day)
S <- 51
P <- length(unique(df$pollster))
M <- length(unique(df$method))
Pop <- length(unique(df$polltype))

state <- df %>% filter(index_s != 52) %>% pull(index_s)
day_national <- df %>% filter(index_s == 52) %>% pull(poll_day) 
day_state <- df %>% filter(index_s != 52) %>% pull(poll_day) 
poll_national <- df %>% filter(index_s == 52) %>% pull(index_p) 
poll_state <- df %>% filter(index_s != 52) %>% pull(index_p) 
#poll_mode_national <- df %>% filter(index_s == 52) %>% pull(index_m) 
#poll_mode_state <- df %>% filter(index_s != 52) %>% pull(index_m) 
#poll_pop_national <- df %>% filter(index_s == 52) %>% pull(index_pop) 
#poll_pop_state <- df %>% filter(index_s != 52) %>% pull(index_pop) 

n_democrat_national <- df %>% filter(index_s == 52) %>% pull(n_obama)
n_democrat_state <- df %>% filter(index_s != 52) %>% pull(n_obama)
n_two_share_national <- df %>% filter(index_s == 52) %>% transmute(n_two_share = n_romney + n_obama) %>% pull(n_two_share)
n_two_share_state <- df %>% filter(index_s != 52) %>% transmute(n_two_share = n_romney + n_obama) %>% pull(n_two_share)
unadjusted_national <- df %>% mutate(unadjusted = ifelse(!(pollster %in% adjusters), 1, 0)) %>% filter(index_s == 52) %>% pull(unadjusted)
unadjusted_state <- df %>% mutate(unadjusted = ifelse(!(pollster %in% adjusters), 1, 0)) %>% filter(index_s != 52) %>% pull(unadjusted)


# priors (on the logit scale)
sigma_measure_noise_national <- 0.04
sigma_measure_noise_state <- 0.04
sigma_a <- 0.012
sigma_c <- 0.06
sigma_m <- 0.04
sigma_pop <- 0.04
sigma_e_bias <- 0.02

polling_bias_scale <- as.numeric(polling_bias_scale) * 4
mu_b_T_scale <- as.numeric(mu_b_T_scale) * 4
random_walk_scale <- as.numeric(random_walk_scale) * 4

# put the data in a list to export to Stan
data <- list(
  N_national_polls = N_national_polls,
  N_state_polls = N_state_polls,
  T = T,
  #current_T = as.integer(current_T),
  S = S,
  P = P,
  M = M,
  Pop = Pop,
  state = state,
  state_weights = state_weights,
  day_state = as.integer(day_state),
  day_national = as.integer(day_national),
  poll_state = poll_state,
  poll_national = poll_national,
  #poll_mode_national = poll_mode_national, 
  #poll_mode_state = poll_mode_state,
  #poll_pop_national = poll_pop_national, 
  #poll_pop_state = poll_pop_state,
  unadjusted_national = unadjusted_national,
  unadjusted_state = unadjusted_state,
  n_democrat_national = n_democrat_national,
  n_democrat_state = n_democrat_state,
  n_two_share_national = n_two_share_national,
  n_two_share_state = n_two_share_state,
  sigma_a = sigma_a,
  sigma_measure_noise_national = sigma_measure_noise_national,
  sigma_measure_noise_state = sigma_measure_noise_state,
  mu_b_prior = mu_b_prior,
  sigma_c = sigma_c,
  sigma_m = sigma_m,
  sigma_pop = sigma_pop,
  sigma_e_bias = sigma_e_bias,
  # covariance matrices
  # ss_cov_mu_b_walk = state_covariance_mu_b_walk,
  # ss_cov_mu_b_T = state_covariance_mu_b_T,
  # ss_cov_poll_bias = state_covariance_polling_bias,
  state_covariance_0 = state_covariance_0,
  polling_bias_scale = polling_bias_scale,
  mu_b_T_scale = mu_b_T_scale,
  random_walk_scale = random_walk_scale
)

# run the Stan model ------------------------------------------------------
message("Running model...")
# model options
#("scripts/model/poll_model_2020_no_partisan_correction.stan")
#("scripts/model/poll_model_2020_no_mode_adjustment.stan")
#("scripts/model/poll_model_2020.stan")

# if rstan, uncomment these lines:
# model <- rstan::stan_model("scripts/model/poll_model_2020.stan")
# out <- rstan::sampling(model, data = data,
#                        refresh = n_refresh,
#                        chains  = n_chains, iter = 500, warmup = 250
# )

# else if cmdstan, uncomment these
model <- cmdstanr::cmdstan_model("scripts/model/poll_model_2020_no_mode_adjustment.stan",compile=TRUE,force=TRUE)
fit <- model$sample(
  data = data,
  seed = 1843,
  parallel_chains = n_cores,
  chains = n_chains,
  iter_warmup = n_warmup,
  iter_sampling = n_sampling,
  refresh = n_refresh
)

out <- rstan::read_stan_csv(fit$output_files())
rm(fit)
gc()

# save model for today
write_rds(out, sprintf('models/backtest_2012/stan_model_%s.rds',RUN_DATE),compress = 'gz')

# extracting results ----
out <- read_rds(sprintf('models/backtest_2012/stan_model_%s.rds',RUN_DATE))

## --- priors
## mu_b_T
y <- MASS::mvrnorm(1000, mu_b_prior, Sigma = state_covariance_mu_b_T/4)
mu_b_T_posterior_draw <- rstan::extract(out, pars = "mu_b")[[1]][,,250]
mu_b_T_prior_draws     <- mean_low_high(y, states = colnames(y), id = "prior")
mu_b_T_posterior_draws <- mean_low_high(mu_b_T_posterior_draw, states = colnames(y), id = "posterior")
mu_b_T <- rbind(mu_b_T_prior_draws, mu_b_T_posterior_draws)
mu_b_t_plt <- mu_b_T %>% arrange(mean) %>%
  ggplot(.) +
  geom_point(aes(y = mean, x = reorder(state, mean), color = type), position = position_dodge(width = 0.5)) +
  geom_errorbar(aes(ymin = low, ymax = high, x = state, color = type), width = 0, position = position_dodge(width = 0.5)) +
  coord_flip() +
  theme_bw()
mu_b_t_plt
## mu_c
mu_c_posterior_draws <- rstan::extract(out, pars = "mu_c")[[1]] 
mu_c_posterior_draws <- data.frame(draws = as.vector(mu_c_posterior_draws),
                                   index_p = sort(rep(seq(1, P), dim(mu_c_posterior_draws)[1])), 
                                   type = "posterior")
mu_c_prior_draws <- data.frame(draws = rnorm(P * 1000, 0, sigma_c),
                               index_p = sort(rep(seq(1, P), 1000)), 
                               type = "prior")
mu_c_draws <- rbind(mu_c_posterior_draws, mu_c_prior_draws) 
pollster <- df %>% select(pollster, index_p) %>% distinct()
mu_c_draws <- merge(mu_c_draws, pollster, by = "index_p", all.x = TRUE)
mu_c_draws <- mu_c_draws %>%
  group_by(pollster, type) %>%
  summarize(mean = mean(draws), 
            low = mean(draws) - 1.96 * sd(draws),
            high = mean(draws) + 1.96 * sd(draws))
mu_c_plt <- mu_c_draws %>% 
  arrange(mean) %>% 
  filter(pollster %in% (df %>% group_by(pollster) %>% 
                          summarise(n=n()) %>% filter(n>=5) %>% pull(pollster))) %>%
  ggplot(.) +
  geom_point(aes(y = mean, x = reorder(pollster, mean), color = type), 
             position = position_dodge(width = 0.5)) +
  geom_errorbar(aes(ymin = low, ymax = high, x = pollster, color = type), 
                width = 0, position = position_dodge(width = 0.5)) +
  coord_flip() +
  theme_bw()
mu_c_plt
#write_csv(mu_c_draws,'output/mu_c_draws_2016.csv')
## state error terms
polling_bias_posterior <- rstan::extract(out, pars = "polling_bias")[[1]]
polling_bias_posterior %>% apply(.,2,sd) / 4

polling_bias_posterior_draws <- data.frame(draws = as.vector(polling_bias_posterior),
                                           index_s = sort(rep(seq(1, S), dim(polling_bias_posterior)[1])), 
                                           type = "posterior")
y <- MASS::mvrnorm(1000, rep(0, S), Sigma = state_covariance_polling_bias)
polling_bias_prior_draws <- data.frame(draws = as.vector(y),
                                       index_s = sort(rep(seq(1, S), dim(y)[1])), 
                                       type = "prior")
polling_bias_draws <- rbind(polling_bias_posterior_draws, polling_bias_prior_draws) 
states <- data.frame(index_s = 1:51, states = rownames(state_correlation_polling))
polling_bias_draws <- merge(polling_bias_draws, states, by = "index_s", all.x = TRUE)
polling_bias_draws <- polling_bias_draws %>%
  group_by(states, type) %>%
  summarize(mean = mean(draws), 
            low = mean(draws) - 1.96 * sd(draws),
            high = mean(draws) + 1.96 * sd(draws))
polling_bias_plt <- polling_bias_draws %>%
  ggplot(.) +
  geom_point(aes(y = mean, x = reorder(states, mean), color = type), 
             position = position_dodge(width = 0.5)) +
  geom_errorbar(aes(ymin = low, ymax = high, x = states, color = type), 
                width = 0, position = position_dodge(width = 0.5)) +
  coord_flip() +
  theme_bw()
polling_bias_plt
## Posterior

# states
predicted_score <- rstan::extract(out, pars = "predicted_score")[[1]]

# state correlation?
single_draw <- as.data.frame(predicted_score[,dim(predicted_score)[2],])
names(single_draw) <- colnames(state_correlation_polling)
single_draw %>% 
  select(AL,CA,FL,MN,NC,NM,RI,WI) %>%  #NV,FL,WI,MI,NH,OH,IA,NC,IN
  cor 

pct_obama <- pblapply(1:dim(predicted_score)[3],
                        function(x){
                          # pred is mu_a + mu_b for the past, just mu_b for the future
                          temp <- predicted_score[,,x]
                          
                          # put in tibble
                          tibble(low = apply(temp,2,function(x){(quantile(x,0.025))}),
                                 high = apply(temp,2,function(x){(quantile(x,0.975))}),
                                 mean = apply(temp,2,function(x){(mean(x))}),
                                 prob = apply(temp,2,function(x){(mean(x>0.5))}),
                                 state = x) 
                          
                        }) %>% do.call('bind_rows',.)

pct_obama$state = colnames(state_correlation_polling)[pct_obama$state]

pct_obama <- pct_obama %>%
  group_by(state) %>%
  mutate(t = row_number() + min(df$begin)) %>%
  ungroup()

# national
pct_obama_natl <- pblapply(1:dim(predicted_score)[1],
                             function(x){
                               # each row is a day for a particular draw
                               temp <- predicted_score[x,,] %>% as.data.frame()
                               names(temp) <- colnames(state_correlation_polling)
                               
                               # for each row, get weigted natl vote
                               tibble(natl_vote = apply(temp,MARGIN = 1,function(y){weighted.mean(y,state_weights)})) %>%
                                 mutate(t = row_number() + min(df$begin)) %>%
                                 mutate(draw = x)
                             }) %>% do.call('bind_rows',.)

pct_obama_natl <- pct_obama_natl %>%
  group_by(t) %>%
  summarise(low = quantile(natl_vote,0.025),
            high = quantile(natl_vote,0.975),
            mean = mean(natl_vote),
            prob = mean(natl_vote > 0.5)) %>%
  mutate(state = '--')

# bind state and national vote
pct_obama <- pct_obama %>%
  bind_rows(pct_obama_natl) %>%
  arrange(desc(mean))

# look
ex_states <- c('IA','FL','OH','WI','MI','PA','AZ','NC','NH','NV','GA','MN')
pct_obama %>% filter(t == RUN_DATE,state %in% c(ex_states,'--')) %>% mutate(se = (high - mean)/1.96) %>% dplyr::select(-t) %>% print
pct_obama %>% filter(t == election_day,state %in% c(ex_states,'--')) %>% mutate(se = (high - mean)/1.96) %>% dplyr::select(-t) %>% print

map.gg <- urbnmapr::states %>%
  left_join(pct_obama %>% filter(t == max(t)) %>%
              select(state_abbv=state,prob)) %>%
  ggplot(aes(x=long,y=lat,group=group,fill=prob)) +
  geom_polygon()  + 
  coord_map("albers",lat0=39, lat1=45) +
  scale_fill_gradient2(high='blue',low='red',mid='white',midpoint=0.5) +
  theme_void()

print(map.gg)

# electoral college by simulation
draws <- pblapply(1:dim(predicted_score)[3],
                  function(x){
                    # pred is mu_a + mu_b for the past, just mu_b for the future
                    pct_obama <- predicted_score[,,x]
                    
                    pct_obama <- pct_obama %>%
                      as.data.frame() %>%
                      mutate(draw = row_number()) %>%
                      gather(t,pct_obama,1:(ncol(.)-1)) %>%
                      mutate(t = as.numeric(gsub('V','',t)) + min(df$begin),
                             state = colnames(state_correlation_polling)[x]) 
                  }) %>% do.call('bind_rows',.)


sim_evs <- draws %>%
  left_join(states2008 %>% select(state,ev),by='state') %>%
  group_by(t,draw) %>%
  summarise(dem_ev = sum(ev * (pct_obama > 0.5))) %>%
  group_by(t) %>%
  summarise(mean_dem_ev = mean(dem_ev),
            median_dem_ev = median(dem_ev),
            high_dem_ev = quantile(dem_ev,0.975),
            low_dem_ev = quantile(dem_ev,0.025),
            prob = mean(dem_ev >= 270))

identifier <- paste0(Sys.Date()," || " , out@model_name)

natl_polls.gg <- pct_obama %>%
  filter(state == '--') %>%
  left_join(df %>% select(state,t,pct_obama)) %>% # plot over time
  # plot
  ggplot(.,aes(x=t)) +
  geom_ribbon(aes(ymin=low,ymax=high),col=NA,alpha=0.2) +
  geom_hline(yintercept = 0.5) +
  geom_hline(yintercept = national_mu_prior,linetype=2) +
  geom_point(aes(y=pct_obama),alpha=0.3) +
  geom_line(aes(y=mean)) +
  facet_wrap(~state) +
  theme_minimal()  +
  theme(legend.position = 'none') +
  scale_x_date(limits=c(ymd('2012-03-01','2012-11-06')),date_breaks='1 month',date_labels='%b') +
  scale_y_continuous(breaks=seq(0,1,0.02)) + 
  labs(subtitletitle=sprintf('obama natl pct | mean = %s | p(win) = %s',
                             round(pct_obama[pct_obama$state=='--' & pct_obama$t==election_day,]$mean*100,1),
                             round(pct_obama[pct_obama$state=='--' & pct_obama$t==election_day,]$prob,2)))

natl_evs.gg <-  ggplot(sim_evs, aes(x=t)) +
  geom_hline(yintercept = 270) +
  geom_line(aes(y=median_dem_ev)) +
  geom_ribbon(aes(ymin=low_dem_ev,ymax=high_dem_ev),alpha=0.2) +
  theme_minimal()  +
  theme(legend.position = 'none') +
  scale_x_date(limits=c(ymd('2012-03-01','2012-11-06')),date_breaks='1 month',date_labels='%b') +
  labs(subtitletitle=sprintf('obama evs | median = %s | p(win) = %s',
                             round(sim_evs[sim_evs$t==election_day,]$median_dem_ev),
                             round(sim_evs[sim_evs$t==election_day,]$prob,2)))

state_polls.gg <- pct_obama %>%
  filter(state %in% ex_states) %>%
  left_join(df %>% select(state,t,pct_obama)) %>% 
  left_join(tibble(state = names(mu_b_prior),
                   prior = inv.logit(mu_b_prior)) ) %>%
  ggplot(.,aes(x=t,col=state)) +
  geom_ribbon(aes(ymin=low,ymax=high),col=NA,alpha=0.2) +
  geom_hline(yintercept = 0.5) +
  geom_hline(aes(yintercept = prior),linetype=2) +
  geom_point(aes(y=pct_obama),alpha=0.3) +
  geom_line(aes(y=mean)) +
  facet_wrap(~state) +
  theme_minimal()  +
  theme(legend.position = 'top') +
  guides(color='none') +
  scale_x_date(limits=c(ymd('2012-03-01','2012-11-06')),date_breaks='1 month',date_labels='%b') +
  labs(subtitle='pct_obama state')


grid.arrange(natl_polls.gg, natl_evs.gg, state_polls.gg, 
             layout_matrix = rbind(c(1,1,3,3,3),
                                   c(2,2,3,3,3)),
             top = identifier
)


# what's the tipping point state?
tipping_point <- draws %>%
  filter(t == election_day) %>%
  left_join(states2008 %>% dplyr::select(state,ev),by='state') %>%
  left_join(enframe(state_weights,'state','weight')) %>%
  group_by(draw) %>%
  mutate(dem_nat_pop_vote = weighted.mean(pct_obama,weight))

tipping_point <- pblapply(1:max(tipping_point$draw),
                          cl = parallel::detectCores() - 1,
                          function(x){
                            temp <- tipping_point[tipping_point$draw==x,]
                            
                            if(temp$dem_nat_pop_vote > 0.5){
                              temp <- temp %>% arrange(desc(pct_obama))
                            }else{
                              temp <- temp %>% arrange(pct_obama)
                            }
                            
                            return(temp)
                          }) %>%
  do.call('bind_rows',.)

tipping_point %>%
  mutate(cumulative_ev = cumsum(ev)) %>%
  filter(cumulative_ev >= 270) %>%
  filter(row_number() == 1) %>% 
  group_by(state) %>%
  summarise(prop = n()) %>%
  mutate(prop = prop / sum(prop)) %>%
  arrange(desc(prop)) 

# probs v other forecasters
ggplot(sim_evs, aes(x=t)) +
  geom_hline(yintercept = 0.5) +
  geom_line(aes(y=prob))  +
  coord_cartesian(ylim=c(0,1)) +
  geom_hline(data=tibble(forecaster = c('nyt',
                                        'fivethirtyeight',
                                        'huffpost',
                                        'predictwise',
                                        'pec',
                                        'dailykos',
                                        'morris16'),
                         prob = c(0.85,0.71,0.98,0.89,0.99,0.92,0.84)),
             aes(yintercept=prob,col=forecaster),linetype=2) +
  labs(subtitle = identifier)


# now-cast probability over time all states
pct_obama %>%
  ggplot(.,aes(x=t,y=prob,col=state)) +
  geom_hline(yintercept=0.5) +
  geom_line() +
  geom_label_repel(data = pct_obama %>% 
                     filter(t==max(t),
                            prob > 0.1 & prob < 0.9),
                   aes(label=state)) +
  theme_minimal()  +
  theme(legend.position = 'none') +
  scale_x_date(limits=c(ymd('2012-03-01','2012-11-06')),date_breaks='1 month',date_labels='%b') +
  scale_y_continuous(breaks=seq(0,1,0.1)) +
  labs(subtitle = identifier)

# diff from national over time?
pct_obama[pct_obama$state != '--',] %>%
  left_join(pct_obama[pct_obama$state=='--',] %>%
              select(t,pct_obama_national=mean), by='t') %>%
  mutate(diff=mean-pct_obama_national) %>%
  group_by(state) %>%
  mutate(last_prob = last(prob)) %>%
  filter(state %in% ex_states) %>%
  ggplot(.,aes(x=t,y=diff,col=state)) +
  geom_hline(yintercept=0.0) +
  geom_line() +
  geom_label_repel(data = . %>% 
                     filter(t==max(t),
                            prob > 0.1 & prob < 0.9),
                   aes(label=state)) +
  theme_minimal()  +
  theme(legend.position = 'none') +
  scale_x_date(limits=c(ymd('2012-03-01','2012-11-06')),date_breaks='1 month',date_labels='%b') +
  scale_y_continuous(breaks=seq(-1,1,0.01)) +
  labs(subtitle = identifier)

# final EV distribution
final_evs <- draws %>%
  left_join(states2008 %>% select(state,ev),by='state') %>%
  filter(t==max(t)) %>%
  group_by(draw) %>%
  summarise(dem_ev = sum(ev* (pct_obama > 0.5)))

ev.gg <- ggplot(final_evs,aes(x=dem_ev,
                              fill=ifelse(dem_ev>=270,'Democratic','Republican'))) +
  geom_vline(xintercept = 270) +
  geom_histogram(binwidth=1) +
  theme_minimal() +
  theme(legend.position = 'top',
        panel.grid.minor = element_blank()) +
  scale_fill_manual(name='Electoral College winner',values=c('Democratic'='#3A4EB1','Republican'='#E40A04')) +
  labs(x='Democratic electoral college votes',
       subtitle=sprintf("p(dem win) = %s",round(mean(final_evs$dem_ev>=270),2)) )


print(ev.gg)

# brier scores
# https://www.buzzfeednews.com/article/jsvine/2016-election-forecast-grades
ev_state <- enframe(ev_state)
colnames(ev_state) <- c("state", "ev")
compare <- pct_obama %>% 
  filter(t==max(t),state!='--') %>% 
  select(state,obama_win=prob) %>% 
  mutate(obama_win_actual = ifelse(state %in% c('CA','NV','OR','WA','CO','NM','MN','IL','VA','DC','MD','DE','NJ','CT','RI','MA','NH','VT','NY','HI','ME',
                                                'MI','WI','PA','OH','IA','NC'),1,0),
         diff = (obama_win_actual - obama_win )^2) %>% 
  left_join(ev_state) %>% 
  mutate(ev_weight = ev/(sum(ev))) 

tibble(outlet='economist (backtest)',
       ev_wtd_brier = weighted.mean(compare$diff, compare$ev_weight),
       unwtd_brier = mean(compare$diff),
       states_correct=sum(round(compare$obama_win) == round(compare$obama_win_actual)))

