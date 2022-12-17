defmodule Scholar.Decomposition.PCA do
  @moduledoc """
  PCA decomposition algorithm.
  """
  import Nx.Defn

  @derive {Nx.Container,
           keep: [:num_components],
           containers: [
             :components,
             :explained_variance,
             :explained_variance_ratio,
             :singular_values,
             :mean,
             :num_features,
             :num_samples
           ]}
  defstruct [
    :components,
    :explained_variance,
    :explained_variance_ratio,
    :singular_values,
    :mean,
    :num_components,
    :num_features,
    :num_samples
  ]

  fit_opts_schema = [
    num_components: [
      type: {:or, [:pos_integer, {:in, [nil]}]},
      default: nil,
      doc: ~S"""
      Number of components to keep. If `:num_components` is not set, all components are kept:

      $num\\_components = min(num\\_samples, num\\_features)$
      """
    ]
  ]

  transform_opts_schema = [
    whiten: [
      type: :boolean,
      default: false,
      doc: """
      When true the result is multiplied by the square root of `:num_samples` and then
      divided by the `:singular_values` to ensure uncorrelated outputs with unit component-wise variances.

      Whitening will remove some information from the transformed signal (the relative variance scales of the components)
      but can sometime improve the predictive accuracy of the downstream estimators by making their data respect some hard-wired assumptions.

      """
    ]
  ]

  fit_transform_opts_schema = fit_opts_schema ++ transform_opts_schema

  @fit_opts_schema NimbleOptions.new!(fit_opts_schema)
  @transform_opts_schema NimbleOptions.new!(transform_opts_schema)
  @fit_transform_opts_schema NimbleOptions.new!(fit_transform_opts_schema)

  @doc """
  Fits a PCA for sample inputs `x`.

  ## Options

  #{NimbleOptions.docs(@fit_opts_schema)}

  ## Returns

  The function returns a struct with the following parameters:

    * `:components` - Principal axes in feature space, representing the directions of maximum variance in the data.
      Equivalently, the right singular vectors of the centered input data, parallel to its eigenvectors.
      The components are sorted by `:explained_variance`.

    * `:explained_variance` - The amount of variance explained by each of the selected components.
      The variance estimation uses `:num_samples - 1` degrees of freedom.
      Equal to `:num_components` largest eigenvalues of the covariance matrix of `x`.

    * `:explained_variance_ratio` - Percentage of variance explained by each of the selected components.
      If `:num_components` is not set then all components are stored and the sum of the ratios is equal to 1.0.

    * `:singular_values` - The singular values corresponding to each of the selected components.
      The singular values are equal to the 2-norms of the `:num_components` variables in the lower-dimensional space.

    * `:mean` - Per-feature empirical mean, estimated from the training set.

    * `:num_components` - It equals the parameter `:num_components`, or the lesser
      value of `:num_features` and `:num_samples` if the parameter `:num_components` is `nil`.

    * `:num_features` - Number of features in the training data.

    * `:num_samples` - Number of samples in the training data.
  """
  deftransform fit(x, opts \\ []) do
    fit_n(x, NimbleOptions.validate!(opts, @fit_opts_schema))
  end

  # TODO Add support for :num_components as a float when dynamic shapes will be implemented
  defnp fit_n(x, opts \\ []) do
    if Nx.rank(x) != 2 do
      raise ArgumentError, "expected x to have rank equal to: 2, got: #{inspect(Nx.rank(x))}"
    end

    {num_samples, num_features} = Nx.shape(x)
    num_components = opts[:num_components]

    mean = Nx.mean(x, axes: [0])
    x = x - mean
    {decomposer, singular_values, components} = Nx.LinAlg.svd(x)

    {num_components, trim_dim} =
      calculate_num_components(
        num_components,
        num_features,
        num_samples
      )

    {_, components} = flip_svd(decomposer[[0..-1//1, 0..(trim_dim - 1)]], components)
    components = components[[0..(num_components - 1), 0..-1//1]]

    explained_variance = singular_values * singular_values / (num_samples - 1)

    explained_variance_ratio =
      (explained_variance / Nx.sum(explained_variance))[[0..(num_components - 1)]]

    %__MODULE__{
      components: components,
      explained_variance: explained_variance[[0..(num_components - 1)]],
      explained_variance_ratio: explained_variance_ratio,
      singular_values: singular_values[[0..(num_components - 1)]],
      mean: mean,
      num_components: num_components,
      num_features: num_features,
      num_samples: num_samples
    }
  end

  @doc """
  For a fitted model performs a decomposition.

  ## Options

  #{NimbleOptions.docs(@transform_opts_schema)}

  ## Returns

  The function returns a decomposed data.
  """
  deftransform transform(model, x, opts \\ []) do
    transform_n(model, x, NimbleOptions.validate!(opts, @transform_opts_schema))
  end

  defnp transform_n(
          %__MODULE__{
            components: components,
            explained_variance: explained_variance,
            mean: mean
          } = _model,
          x,
          opts \\ []
        ) do
    whiten? = opts[:whiten]

    x = x - mean

    x_transformed = Nx.dot(x, [1], components, [1])

    if whiten? do
      x_transformed / Nx.sqrt(explained_variance)
    else
      x_transformed
    end
  end

  @doc """
  Fit the model with `x` and apply the dimensionality reduction on `x`.
  This function is analogical to calling fit and then transform, but it is calculated
  more efficiently.

  ## Options

  #{NimbleOptions.docs(@transform_opts_schema)}

  ## Returns

  The function returns a decomposed data.
  """

  deftransform fit_transform(x, opts \\ []) do
    fit_transform_n(x, NimbleOptions.validate!(opts, @fit_transform_opts_schema))
  end

  defnp fit_transform_n(x, opts \\ []) do
    if Nx.rank(x) != 2 do
      raise ArgumentError, "expected x to have rank equal to: 2, got: #{inspect(Nx.rank(x))}"
    end

    {num_samples, num_features} = Nx.shape(x)
    num_components = opts[:num_components]
    x = x - Nx.mean(x, axes: [0])
    {decomposer, singular_values, components} = Nx.LinAlg.svd(x)

    {num_components, trim_dim} =
      calculate_num_components(
        num_components,
        num_features,
        num_samples
      )

    {decomposer, _components} = flip_svd(decomposer[[0..-1//1, 0..(trim_dim - 1)]], components)
    decomposer = decomposer[[0..-1//1, 0..(num_components - 1)]]

    if opts[:whiten] do
      decomposer * Nx.sqrt(num_samples - 1)
    else
      decomposer * singular_values[[0..(num_components - 1)]]
    end
  end

  defnp flip_svd(u, v) do
    # columns of u, rows of v
    max_abs_cols_idx = u |> Nx.abs() |> Nx.argmax(axis: 0, keep_axis: true)
    signs = u |> Nx.take_along_axis(max_abs_cols_idx, axis: 0) |> Nx.sign() |> Nx.squeeze()
    u = u * signs
    v = v * Nx.new_axis(signs, -1)
    {u, v}
  end

  deftransformp calculate_num_components(
                  num_components,
                  num_features,
                  num_samples
                ) do
    default_num_components = min(num_features, num_samples)

    cond do
      num_components == nil ->
        {default_num_components, default_num_components}

      num_components > 0 and num_components <= min(num_features, num_samples) and
          is_integer(num_components) ->
        {num_components, default_num_components}

      is_integer(num_components) ->
        raise ArgumentError,
              "expected :num_components to be integer in range 1 to #{inspect(min(num_samples, num_features))}, got: #{inspect(num_components)}"

      true ->
        raise ArgumentError, "unexpected type of :num_components, got: #{inspect(num_components)}"
    end
  end
end