#  SPDX-License-Identifier: BSD-2-Clause
#
#  configuration_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2025 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe GitHubApp::Configuration do
  let(:config_path) { File.expand_path('config.yml', File.join(File.dirname(__FILE__), '../../../')) }
  let(:default_config) do
    {
      'debug' => true,
      'ci' => { 'url' => 'https://custom.ci.url' }
    }
  end

  before do
    allow(YAML).to receive(:load_file).and_return(default_config)
    if described_class.instance_variable_defined?(:@singleton__instance__)
      described_class.__send__(:remove_instance_variable, :@singleton__instance__)
    end
  end

  after do
    if described_class.instance_variable_defined?(:@singleton__instance__)
      described_class.__send__(:remove_instance_variable, :@singleton__instance__)
    end
  end

  describe '.instance' do
    it 'returns a singleton instance' do
      expect(described_class.instance).to be_a(described_class)
      expect(described_class.instance).to equal(described_class.instance)
    end
  end

  describe '#config' do
    it 'loads the configuration from YAML' do
      expect(described_class.instance.config).to eq(default_config)
    end
  end

  describe '#debug?' do
    context 'when debug is true' do
      it 'returns true' do
        expect(described_class.instance.debug?).to be true
      end
    end

    context 'when debug is false' do
      before do
        allow(YAML).to receive(:load_file).and_return(default_config.merge('debug' => false))
      end

      it 'returns false' do
        expect(described_class.instance.debug?).to be false
      end
    end

    context 'when debug key is missing' do
      before do
        allow(YAML).to receive(:load_file).and_return(default_config.except('debug'))
      end

      it 'returns false' do
        expect(described_class.instance.debug?).to be false
      end
    end
  end

  describe '#ci_url' do
    context 'when ci url is present' do
      it 'returns the configured ci url' do
        expect(described_class.instance.ci_url).to eq('https://custom.ci.url')
      end
    end

    context 'when ci key is missing' do
      before do
        allow(YAML).to receive(:load_file).and_return(default_config.except('ci'))
      end

      it 'returns the default ci url' do
        expect(described_class.instance.ci_url).to eq('https://ci1.netdef.org')
      end
    end

    context 'when ci url is missing' do
      before do
        allow(YAML).to receive(:load_file).and_return(default_config.merge('ci' => {}))
      end

      it 'returns the default ci url' do
        expect(described_class.instance.ci_url).to eq('https://ci1.netdef.org')
      end
    end
  end

  describe '#bamboo_service_account' do
    let(:env) { {} }

    before { stub_const('ENV', ENV.to_h.except('BAMBOO_CLIENT_ID', 'BAMBOO_CLIENT_SECRET').merge(env)) }

    context 'when nothing is configured' do
      it 'returns nil' do
        expect(described_class.instance.bamboo_service_account).to be_nil
      end
    end

    context 'when config.yml has the client id and secret' do
      before do
        allow(YAML).to receive(:load_file)
          .and_return(default_config.merge('bamboo' => { 'client_id' => 'yml-id', 'client_secret' => 'yml-secret' }))
      end

      it 'returns them' do
        expect(described_class.instance.bamboo_service_account).to eq(%w[yml-id yml-secret])
      end

      context 'when the environment has them too' do
        let(:env) { { 'BAMBOO_CLIENT_ID' => 'env-id', 'BAMBOO_CLIENT_SECRET' => ' env-secret ' } }

        it 'prefers the environment' do
          expect(described_class.instance.bamboo_service_account).to eq(%w[env-id env-secret])
        end
      end
    end

    context 'when only the client id is set' do
      let(:env) { { 'BAMBOO_CLIENT_ID' => 'env-id' } }

      it 'returns nil' do
        expect(described_class.instance.bamboo_service_account).to be_nil
      end
    end
  end

  describe '#bamboo_oauth_scope' do
    before { stub_const('ENV', ENV.to_h.except('BAMBOO_OAUTH_SCOPE').merge(env)) }

    context 'when nothing is configured' do
      let(:env) { {} }

      it 'returns the default scope' do
        expect(described_class.instance.bamboo_oauth_scope).to eq('READ TRIGGER WRITE')
      end
    end

    context 'when config.yml sets the scope' do
      let(:env) { {} }

      before do
        allow(YAML).to receive(:load_file).and_return(default_config.merge('bamboo' => { 'oauth_scope' => 'READ' }))
      end

      it 'returns it' do
        expect(described_class.instance.bamboo_oauth_scope).to eq('READ')
      end
    end

    context 'when the environment sets an empty scope' do
      let(:env) { { 'BAMBOO_OAUTH_SCOPE' => '' } }

      it 'returns nil (no scope sent)' do
        expect(described_class.instance.bamboo_oauth_scope).to be_nil
      end
    end
  end

  describe '#reload' do
    it 'reloads the configuration' do
      expect(YAML).to receive(:load_file).twice.and_return(default_config)
      instance = described_class.instance
      instance.reload
    end
  end
end
